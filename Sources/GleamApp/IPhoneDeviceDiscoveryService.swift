import Foundation

struct IPhoneLocationPaths {
    let projectRoot: URL?

    var pythonExecutable: URL? {
        projectRoot?.appendingPathComponent(".venv/bin/python", isDirectory: false)
    }

    var bridgeScript: URL? {
        projectRoot?.appendingPathComponent("scripts/iphone_location_bridge.py", isDirectory: false)
    }

    var setupScriptPath: String {
        projectRoot?.appendingPathComponent("scripts/setup.sh").path ?? "scripts/setup.sh"
    }
}

enum IPhoneDeviceDiscoveryError: LocalizedError {
    case projectRootMissing
    case dependencyMissing(String)
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .projectRootMissing:
            return "无法定位项目目录，请通过项目脚本重新启动 App。"
        case .dependencyMissing(let setupPath):
            return "iPhone 定位依赖尚未安装，请先运行 \(setupPath)。"
        case .commandFailed(let detail):
            return detail.isEmpty
                ? "无法读取 iPhone，请确认设备已通过 USB 连接、解锁并信任此 Mac。"
                : "无法读取 iPhone：\(detail)"
        case .invalidResponse:
            return "设备服务返回的数据无法解析，请重新连接 iPhone 后刷新。"
        }
    }
}

enum IPhoneDeviceListParser {
    /// Parses the stable JSON emitted by the local bridge instead of depending on Xcode terminal text.
    static func parse(_ data: Data) throws -> [ConnectedIPhone] {
        let response: DeviceBridgeEvent
        do {
            response = try JSONDecoder().decode(DeviceBridgeEvent.self, from: data)
        } catch {
            throw IPhoneDeviceDiscoveryError.invalidResponse
        }

        guard response.event == "devices" else {
            throw IPhoneDeviceDiscoveryError.invalidResponse
        }
        return response.devices.map {
            ConnectedIPhone(
                id: $0.udid,
                name: $0.name,
                productType: $0.productType,
                osVersion: $0.osVersion,
                transport: $0.transport
            )
        }
    }
}

private struct DeviceBridgeEvent: Decodable {
    let event: String
    let devices: [DevicePayload]

    struct DevicePayload: Decodable {
        let udid: String
        let name: String
        let productType: String
        let osVersion: String
        let transport: String
    }
}

@MainActor
final class IPhoneDeviceDiscoveryService {
    private let paths: IPhoneLocationPaths
    /// Prevents overlapping usbmux scans from racing the panel's selected-device state.
    private var runningProcess: Process?

    init(paths: IPhoneLocationPaths) {
        self.paths = paths
    }

    /// Reads paired USB devices through macOS usbmuxd, which keeps discovery independent of Xcode.
    func loadDevices(completion: @escaping (Result<[ConnectedIPhone], Error>) -> Void) {
        guard runningProcess == nil else {
            return
        }
        guard let pythonExecutable = paths.pythonExecutable, let bridgeScript = paths.bridgeScript else {
            completion(.failure(IPhoneDeviceDiscoveryError.projectRootMissing))
            return
        }
        guard
            FileManager.default.isExecutableFile(atPath: pythonExecutable.path),
            FileManager.default.fileExists(atPath: bridgeScript.path)
        else {
            completion(.failure(IPhoneDeviceDiscoveryError.dependencyMissing(paths.setupScriptPath)))
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = pythonExecutable
        process.arguments = [bridgeScript.path, "devices"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        process.terminationHandler = { [weak self] terminatedProcess in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            Task { @MainActor in
                let errorText = Self.bridgeErrorMessage(from: errorData)
                self?.runningProcess = nil
                guard terminatedProcess.terminationStatus == 0 else {
                    completion(.failure(IPhoneDeviceDiscoveryError.commandFailed(errorText)))
                    return
                }
                do {
                    completion(.success(try IPhoneDeviceListParser.parse(outputData)))
                } catch {
                    completion(.failure(error))
                }
            }
        }

        do {
            try process.run()
            runningProcess = process
        } catch {
            completion(.failure(IPhoneDeviceDiscoveryError.commandFailed(error.localizedDescription)))
        }
    }

    /// Prefers the bridge's structured failure while preserving plain stderr from lower layers.
    private static func bridgeErrorMessage(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(IPhoneBridgeEvent.self, from: data),
            let message = payload.message
        {
            return message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
