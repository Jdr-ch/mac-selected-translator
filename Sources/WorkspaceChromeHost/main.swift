import Foundation
import Darwin

/// Native Messaging 桥只转发同一用户目录中的场景 JSON，不执行命令或解释网页内容。
final class NativeHost {
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let outputLock = NSLock()
    private var profileDirectory: URL?
    private var lockDescriptor: Int32 = -1
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SelectedTextTranslator/WorkspaceScene/bridge")

    /// Chrome 的每帧以前四字节小端长度开头；流式读取避免管道短读破坏消息边界。
    private func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let chunk = try input.read(upToCount: count - result.count), !chunk.isEmpty else {
                return nil
            }
            result.append(chunk)
        }
        return result
    }

    /// 限制单次发给扩展的消息为 1 MB，符合 Chrome Native Messaging 上限。
    private func send(_ data: Data) throws {
        guard data.count <= 1_048_576 else { throw HostError.invalidMessage }
        var length = UInt32(data.count).littleEndian
        outputLock.lock()
        defer { outputLock.unlock() }
        try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try output.write(contentsOf: data)
    }

    /// 资料令牌由扩展生成，每个连接独占一个邮箱，防止不同资料混用场景。
    private func register(_ token: String) throws {
        guard UUID(uuidString: token) != nil, profileDirectory == nil else { throw HostError.invalidMessage }
        let directory = root.appendingPathComponent(token)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("commands"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("responses"), withIntermediateDirectories: true)
        for path in [root, directory, directory.appendingPathComponent("commands"), directory.appendingPathComponent("responses")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        lockDescriptor = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw HostError.alreadyConnected }
        profileDirectory = directory
        try send(JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "kind": "connected"]))
        DispatchQueue.global(qos: .utility).async { [self] in poll(directory, token: token) }
    }

    /// 心跳让 App 判断扩展是否在线；已过期请求直接丢弃，避免重连后重放旧恢复。
    private func poll(_ directory: URL, token: String) {
        while true {
            do {
                let heartbeat: [String: Any] = ["protocolVersion": 1, "profileToken": token,
                    "pid": ProcessInfo.processInfo.processIdentifier, "updatedAt": Date().timeIntervalSince1970]
                try JSONSerialization.data(withJSONObject: heartbeat).write(to: directory.appendingPathComponent("status.json"), options: .atomic)
                let commands = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("commands"), includingPropertiesForKeys: nil)
                for file in commands.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                    let data = try Data(contentsOf: file)
                    let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let deadline = message?["deadline"] as? Double, deadline > Date().timeIntervalSince1970 {
                        try send(data)
                    }
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                // 管道失效时结束桥接进程，Chrome 会按断连流程重新建立连接。
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// 只接收握手与带 UUID 的请求响应，业务错误仍通过 JSON 返回给 App。
    func run() throws {
        while let header = try readExactly(4) {
            let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            guard length > 0, length <= 8_388_608, let data = try readExactly(Int(length)),
                  let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["protocolVersion"] as? Int == 1 else { throw HostError.invalidMessage }
            if message["kind"] as? String == "hello", let token = message["profileToken"] as? String {
                try register(token)
            } else if let directory = profileDirectory, message["kind"] as? String == "result",
                      let requestId = message["requestId"] as? String, UUID(uuidString: requestId) != nil {
                try data.write(to: directory.appendingPathComponent("responses/\(requestId).json"), options: .atomic)
            } else { throw HostError.invalidMessage }
        }
    }

    /// 桥接错误只携带类别，避免把包含网址的消息写入日志。
    private enum HostError: Error { case invalidMessage, alreadyConnected }
}

do {
    try NativeHost().run()
} catch {
    FileHandle.standardError.write(Data("工作场景桥接连接结束。\n".utf8))
    exit(1)
}
