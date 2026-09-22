import Foundation

enum IPhoneLocationState: Equatable {
    case idle
    case startingSimulation
    case simulating(device: ConnectedIPhone, coordinate: IPhoneCoordinate)
    case stoppingSimulation
    case readingCurrentLocation
    case currentLocation(device: ConnectedIPhone, location: CurrentIPhoneLocation)
    case failed(String)
}

enum IPhoneLocationServiceError: LocalizedError {
    case projectRootMissing
    case dependencyMissing(String)
    case processLaunchFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .projectRootMissing:
            return "无法定位项目目录，请通过项目脚本重新启动 App。"
        case .dependencyMissing(let setupPath):
            return "iPhone 定位依赖尚未安装，请先运行 \(setupPath)。"
        case .processLaunchFailed(let detail):
            return "无法启动 iPhone 定位服务：\(detail)"
        case .processFailed(let detail):
            return detail.isEmpty ? "iPhone 拒绝了定位请求。" : "iPhone 定位失败：\(detail)"
        }
    }
}

private enum IPhoneBridgeOperation {
    case set(device: ConnectedIPhone, coordinate: IPhoneCoordinate)
    case clear
    case current(device: ConnectedIPhone)
}

@MainActor
final class IPhoneLocationService {
    private let paths: IPhoneLocationPaths
    /// A retained process means one device operation owns the DVT session.
    private var process: Process?
    /// The pipe keeps simulation alive and acknowledges a consumed current-location payload.
    private var inputPipe: Pipe?
    /// stdout can split one JSON event across callbacks, so parsing waits for a complete line.
    private var outputBuffer = Data()
    /// Retains the command contract until the bridge exits and its final event can be interpreted.
    private var operation: IPhoneBridgeOperation?
    /// Holds a validated phone reading until the acknowledged bridge process exits successfully.
    private var pendingCurrentLocation: CurrentIPhoneLocation?
    /// Drives button availability and status text in the retained location panel.
    private(set) var state: IPhoneLocationState = .idle {
        didSet {
            onStateChange?(state)
        }
    }
    /// Delivers state transitions on the main actor so AppKit controls are updated serially.
    var onStateChange: ((IPhoneLocationState) -> Void)?

    init(paths: IPhoneLocationPaths) {
        self.paths = paths
    }

    /// Starts one long-lived DVT session; retaining the bridge process keeps the override active.
    func startSimulation(device: ConnectedIPhone, coordinate: IPhoneCoordinate) {
        guard process == nil else {
            state = .failed("已有定位操作正在运行，请稍后再试。")
            return
        }
        do {
            let resources = try bridgeResources()
            operation = .set(device: device, coordinate: coordinate)
            state = .startingSimulation
            launchBridge(
                pythonExecutable: resources.python,
                bridgeScript: resources.bridge,
                arguments: [
                    "set", "--udid", device.id,
                    "--latitude", String(coordinate.latitude),
                    "--longitude", String(coordinate.longitude)
                ]
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops this app's retained session, or sends a one-shot clear for an override left by another run.
    func restoreRealLocation(on device: ConnectedIPhone) {
        if let process, process.isRunning, let inputPipe {
            state = .stoppingSimulation
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            try? inputPipe.fileHandleForWriting.close()
            return
        }

        do {
            let resources = try bridgeResources()
            operation = .clear
            state = .stoppingSimulation
            launchBridge(
                pythonExecutable: resources.python,
                bridgeScript: resources.bridge,
                arguments: ["clear", "--udid", device.id]
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Launches the signed iPhone companion, then reads its request-scoped Core Location JSON over USB.
    func requestCurrentLocation(from device: ConnectedIPhone) {
        guard process == nil else {
            state = .failed("已有定位操作正在运行，请稍后再试。")
            return
        }

        do {
            let resources = try bridgeResources()
            operation = .current(device: device)
            pendingCurrentLocation = nil
            state = .readingCurrentLocation
            launchBridge(
                pythonExecutable: resources.python,
                bridgeScript: resources.bridge,
                arguments: ["current", "--udid", device.id]
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Gives a live simulation bridge a brief chance to restore real GPS before the menu app exits.
    func shutdown() {
        guard let process, process.isRunning, let inputPipe else {
            return
        }

        try? inputPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try? inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
        }
    }

    /// Resolves the project-managed Python and bridge, returning setup guidance when either is absent.
    private func bridgeResources() throws -> (python: URL, bridge: URL) {
        guard let pythonExecutable = paths.pythonExecutable, let bridgeScript = paths.bridgeScript else {
            throw IPhoneLocationServiceError.projectRootMissing
        }
        guard
            FileManager.default.isExecutableFile(atPath: pythonExecutable.path),
            FileManager.default.fileExists(atPath: bridgeScript.path)
        else {
            throw IPhoneLocationServiceError.dependencyMissing(paths.setupScriptPath)
        }
        return (pythonExecutable, bridgeScript)
    }

    /// Starts one bridge command and routes its newline-delimited events back to the main actor.
    private func launchBridge(pythonExecutable: URL, bridgeScript: URL, arguments: [String]) {
        let bridgeProcess = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        bridgeProcess.executableURL = pythonExecutable
        bridgeProcess.arguments = [bridgeScript.path] + arguments
        bridgeProcess.standardInput = standardInput
        bridgeProcess.standardOutput = standardOutput
        bridgeProcess.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { @MainActor in
                self?.consumeOutput(data)
            }
        }

        bridgeProcess.terminationHandler = { [weak self] terminatedProcess in
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                self?.bridgeDidTerminate(
                    terminatedProcess,
                    standardOutput: standardOutput,
                    errorText: Self.bridgeErrorMessage(from: errorData)
                )
            }
        }

        do {
            try bridgeProcess.run()
            process = bridgeProcess
            inputPipe = standardInput
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            clearProcessReferences()
            state = .failed(IPhoneLocationServiceError.processLaunchFailed(error.localizedDescription).localizedDescription)
        }
    }

    /// Applies complete bridge events while retaining partial JSON for the next stdout callback.
    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        let newline = Data("\n".utf8)

        while let range = outputBuffer.range(of: newline) {
            let lineData = outputBuffer.subdata(in: outputBuffer.startIndex ..< range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex ... range.lowerBound)
            guard let payload = try? JSONDecoder().decode(IPhoneBridgeEvent.self, from: lineData) else {
                continue
            }

            switch payload.event {
            case "active":
                if case .set(let device, let coordinate) = operation {
                    state = .simulating(device: device, coordinate: coordinate)
                }
            case "current-location":
                if
                    let latitude = payload.latitude,
                    let longitude = payload.longitude,
                    let horizontalAccuracy = payload.horizontalAccuracy
                {
                    pendingCurrentLocation = CurrentIPhoneLocation(
                        coordinate: IPhoneCoordinate(latitude: latitude, longitude: longitude),
                        horizontalAccuracy: horizontalAccuracy
                    )
                    // Acknowledge only after the payload is retained, so process termination cannot win the race.
                    try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                    try? inputPipe?.fileHandleForWriting.close()
                }
            default:
                break
            }
        }
    }

    /// Converts process completion into the final user-visible state for the retained operation.
    private func bridgeDidTerminate(
        _ terminatedProcess: Process,
        standardOutput: Pipe,
        errorText: String
    ) {
        guard process === terminatedProcess else {
            return
        }

        standardOutput.fileHandleForReading.readabilityHandler = nil
        let finishedOperation = operation
        let previousState = state
        let currentLocation = pendingCurrentLocation
        clearProcessReferences()

        if terminatedProcess.terminationStatus != 0 {
            state = .failed(IPhoneLocationServiceError.processFailed(errorText).localizedDescription)
            return
        }

        switch finishedOperation {
        case .clear:
            state = .idle
        case .current(let device):
            if let currentLocation {
                state = .currentLocation(device: device, location: currentLocation)
            } else {
                state = .failed("iPhone 未返回当前定位，请确认伴生 App 已安装并允许定位。")
            }
        case .set:
            if previousState == .stoppingSimulation {
                state = .idle
            } else if case .simulating = previousState {
                state = .failed("定位会话已结束，iPhone 已恢复真实定位。")
            } else {
                state = .failed("定位服务未确认模拟坐标，iPhone 仍使用真实定位。")
            }
        case nil:
            state = .idle
        }
    }

    /// Releases all per-command state only after the terminal event has captured its needed values.
    private func clearProcessReferences() {
        process = nil
        inputPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
        operation = nil
        pendingCurrentLocation = nil
    }

    /// Prefers the bridge's structured failure while preserving plain stderr from device services.
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

struct IPhoneBridgeEvent: Decodable {
    let event: String
    let message: String?
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
}
