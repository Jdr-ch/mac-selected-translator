import Foundation
import Darwin

/// Native Messaging 进程与 App 通过私有用户目录中的原子 JSON 邮箱连接，无常驻外部服务。
@MainActor
final class WorkspaceChromeBridge {
    private let root: URL
    private let chromeRoot: URL

    /// 邮箱和资料目录均可独立指定，让连接规则测试使用临时目录，不读取用户浏览器数据。
    init(root: URL = WorkspaceSceneStore.directory.appendingPathComponent("bridge"),
         chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")) {
        self.root = root
        self.chromeRoot = chromeRoot
    }

    /// 只从扩展安装记录定位资料目录，不读取 Cookie、账号凭证或其他浏览历史。
    func installedProfileDirectory() throws -> String {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: chromeRoot, includingPropertiesForKeys: nil)) ?? []
        var installed: Set<String> = []
        for candidate in candidates where candidate.lastPathComponent == "Default" || candidate.lastPathComponent.hasPrefix("Profile ") {
            for filename in ["Preferences", "Secure Preferences"] {
                guard let data = try? Data(contentsOf: candidate.appendingPathComponent(filename)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = json["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      settings["ldacmagnlnmafacmmfgaeclcllokfjeb"] != nil else { continue }
                installed.insert(candidate.lastPathComponent)
            }
        }
        guard installed.count == 1, let directory = installed.first else {
            throw WorkspaceError.message("无法确定扩展所属的唯一 Chrome 资料，请只在目标资料安装此扩展。")
        }
        return directory
    }

    /// 原连接失效时，仅在唯一连接和唯一安装目录均指向原资料时重新绑定；无连接返回 nil 供启动后等待。
    func restorationProfile(savedProfile: String, profileDirectory: String) throws -> String? {
        let profiles = connectedProfiles()
        if profiles.contains(savedProfile) { return savedProfile }
        guard !profiles.isEmpty else { return nil }
        guard profiles.count == 1, let profile = profiles.first else {
            throw WorkspaceError.message("原 Chrome 连接已失效，当前有多个资料连接，无法确定恢复目标。请只在原资料中启用工作场景助手。")
        }
        guard try installedProfileDirectory() == profileDirectory else {
            throw WorkspaceError.message("当前扩展所属的 Chrome 资料与保存场景不同，请在原资料（\(profileDirectory)）中启用工作场景助手。")
        }
        // 扩展本地存储重建后令牌可能变化；这里只选择本次连接，不改写用户保存的场景。
        return profile
    }

    /// 只接受近期心跳且宿主进程仍存活的资料，避免上次浏览器退出留下的连接误报。
    func connectedProfiles() -> [String] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  status["protocolVersion"] as? Int == 1,
                  let updatedAt = status["updatedAt"] as? Double, Date().timeIntervalSince1970 - updatedAt < 4,
                  let pid = status["pid"] as? Int32, kill(pid, 0) == 0 else { return nil }
            return directory.lastPathComponent
        }.sorted()
    }

    /// 所有响应按 requestId 隔离；超时撤销未发送请求，扩展断线和业务错误分别显示。
    func request<Response: Decodable>(_ command: String, payload: [String: Any] = [:], profile: String,
                                     timeout: TimeInterval = 30, as: Response.Type) async throws -> Response {
        guard connectedProfiles().contains(profile) else { throw WorkspaceError.message("Chrome 扩展未连接，请打开对应用户资料并检查扩展。") }
        let requestId = UUID().uuidString
        let directory = root.appendingPathComponent(profile)
        let requestURL = directory.appendingPathComponent("commands/\(requestId).json")
        let responseURL = directory.appendingPathComponent("responses/\(requestId).json")
        let deadline = Date().addingTimeInterval(timeout)
        let envelope: [String: Any] = ["protocolVersion": 1, "requestId": requestId, "kind": "request",
                                      "command": command, "payload": payload, "deadline": deadline.timeIntervalSince1970]
        let requestData = try JSONSerialization.data(withJSONObject: envelope)
        guard requestData.count <= 1_048_576 else { throw WorkspaceError.message("场景请求超过 Chrome 消息大小限制，请减少单个窗口的标签页。") }
        try requestData.write(to: requestURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }
        while Date() < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: responseURL) {
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      response["requestId"] as? String == requestId, response["protocolVersion"] as? Int == 1 else {
                    throw WorkspaceError.message("Chrome 返回了无法识别的场景响应。")
                }
                guard response["ok"] as? Bool == true else { throw WorkspaceError.message(response["error"] as? String ?? "Chrome 恢复失败。") }
                guard let body = response["payload"] else { throw WorkspaceError.message("Chrome 响应缺少场景内容。") }
                return try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: body))
            }
            guard connectedProfiles().contains(profile) else { throw WorkspaceError.message("Chrome 扩展连接中断，请重新连接后重试。") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // 区分采集和恢复请求未收到响应，不把桥接层超时推断为浏览器弹窗。
        let action = command == "capture" ? "采集窗口" : "恢复窗口"
        throw WorkspaceError.message("等待 Chrome 扩展\(action)响应超时，请检查工作场景助手的连接状态后重试。")
    }

    struct Capture: Decodable {
        var windows: [ChromeWindowSnapshot]
        /// 旧扩展不具备独立窗口分配能力，恢复前必须提示重新加载，不能继续合并群组。
        var windowAllocationVersion: Int?
    }

    func capture(profile: String, requireIndependentWindows: Bool = false) async throws -> [ChromeWindowSnapshot] {
        let result = try await request("capture", profile: profile, as: Capture.self)
        if requireIndependentWindows && result.windowAllocationVersion != 2 {
            throw WorkspaceError.message("请在 Chrome 扩展管理页重新加载“工作场景助手”，再恢复场景。")
        }
        return result.windows
    }

    /// 完整场景编号用于扩展分配独占窗口，单项重试也不能抢占其他场景窗口。
    func restore(_ window: WorkspaceWindow, profile: String, canCreateGroups: [Int], sceneWindowIDs: [String]) async throws -> ChromeWindowSnapshot {
        guard let chrome = window.chrome else { throw WorkspaceError.message("该条目缺少 Chrome 快照。") }
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chrome))
        return try await request("restoreWindow", payload: ["window": body, "logicalId": window.id,
            "canCreateGroups": canCreateGroups, "sceneWindowIds": sceneWindowIDs], profile: profile, timeout: 120, as: ChromeWindowSnapshot.self)
    }
}
