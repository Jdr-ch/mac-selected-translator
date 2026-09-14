import AppKit
import ApplicationServices

/// 单次恢复共用窗口占用表和资源锁；各窗口可以并行等待，Chrome 群组写操作保持独占。
@MainActor
final class WorkspaceRestoreRunner {
    let catalog: WorkspaceWindowCatalog
    let bridge: WorkspaceChromeBridge
    private var assignedWindowIDs: Set<UInt32> = []
    private var gates: [String: WorkspaceOperationGate] = [:]

    init(catalog: WorkspaceWindowCatalog, bridge: WorkspaceChromeBridge) {
        self.catalog = catalog
        self.bridge = bridge
    }

    /// 目标桌面已集中准备；每个条目独立报告结果，最后以实际 Space 和窗口几何回读为准。
    func restore(_ entry: WorkspaceWindow, target: Result<WorkspaceDesktop, Error>?, scene: WorkspaceScene) async -> WorkspaceOutcome {
        do {
            guard entry.issues.isEmpty else { throw WorkspaceError.message(entry.issues.joined(separator: "；")) }
            guard let target else { throw WorkspaceError.message("未准备好\(entry.desktop.label)，请重试。") }
            let desktop = try target.get()
            let native: WorkspaceNativeWindow
            if entry.chrome != nil {
                native = try await restoreChrome(entry, profile: scene.profileToken,
                    profileDirectory: scene.chromeProfileDirectory, sceneWindowIDs: scene.windows.filter { $0.chrome != nil }.map(\.id))
            } else {
                // 相同项目或普通应用共享启动锁；不同 WebStorm 项目仍然并行加载。
                native = try await exclusive("app:\(entry.bundleID):\(entry.projectPath ?? "")") {
                    try await self.restoreApplication(entry)
                }
            }
            guard assignedWindowIDs.insert(native.id).inserted else {
                throw WorkspaceError.message("该窗口已被本次其他条目使用，请检查模板中的重复窗口后重试。")
            }
            let currentTarget = try WorkspaceGeometry.resolve(desktop, in: catalog.desktop.desktops())
            let frame = WorkspaceGeometry.absolute(entry.relativeFrame, in: currentTarget.screenFrame)
            try catalog.applyFrame(frame, to: native)
            try await catalog.desktop.move(native.id, to: currentTarget)
            try catalog.applyFrame(frame, to: native)
            try await waitFor(timeout: 5, failure: "\(entry.label)的桌面或位置验证超时，请重试该条目。") { () async throws -> Bool? in
                guard try self.catalog.desktop.spaces(for: native.id) == [currentTarget.spaceID],
                      let current = WorkspaceWindowCatalog.frame(native.element),
                      WorkspaceWindowCatalog.distance(current, frame) <= 8 else { return nil }
                return true
            }
            return WorkspaceOutcome(windowID: entry.id, label: entry.label)
        } catch {
            return WorkspaceOutcome(windowID: entry.id, label: entry.label, error: error.localizedDescription)
        }
    }

    /// 共享资源临界区只覆盖必须串行的部分；抛错和取消同样释放，后续桌面仍可继续。
    private func exclusive<T>(_ key: String, operation: () async throws -> T) async throws -> T {
        let gate = gates[key] ?? WorkspaceOperationGate()
        gates[key] = gate
        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// 群组恢复后即释放 Chrome 写锁，系统窗口匹配与跨桌面定位可与下一浏览器窗口并行。
    private func restoreChrome(_ entry: WorkspaceWindow, profile: String, profileDirectory: String,
                               sceneWindowIDs: [String]) async throws -> WorkspaceNativeWindow {
        let (connectedProfile, restored) = try await exclusive("chrome") {
            try await self.prepareChrome(entry, profile: profile, profileDirectory: profileDirectory, sceneWindowIDs: sceneWindowIDs)
        }
        return try await waitFor(timeout: 30, failure: "Chrome 已返回恢复结果，但无法唯一匹配“\(entry.label)”的系统窗口，请重试该条目。") {
            let current = try await self.bridge.capture(profile: connectedProfile)
            guard let chrome = current.first(where: { $0.windowId == restored.windowId }) else { return nil }
            let native = try await self.catalog.windows(bundleID: "com.google.Chrome")
            return try? self.catalog.chromeWindow(chrome, among: native)
        }
    }

    /// 已保存但未打开的群组优先通过 Chrome 原生入口打开，防止创建重复的已保存群组。
    private func prepareChrome(_ entry: WorkspaceWindow, profile savedProfile: String, profileDirectory: String,
                               sceneWindowIDs: [String]) async throws -> (String, ChromeWindowSnapshot) {
        guard let snapshot = entry.chrome else { throw WorkspaceError.message("Chrome 快照缺失。") }
        let profile: String
        if let connected = try bridge.restorationProfile(savedProfile: savedProfile, profileDirectory: profileDirectory) {
            profile = connected
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                throw WorkspaceError.message("未安装 Google Chrome。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--profile-directory=\(profileDirectory)"]
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // 每次观察都重新解析原资料的有效连接，避免扩展重载后永远等待旧令牌。
            profile = try await waitFor(timeout: 20, failure: "等待 Chrome 资料（\(profileDirectory)）连接超时，请检查工作场景助手是否已启用。") {
                try self.bridge.restorationProfile(savedProfile: savedProfile, profileDirectory: profileDirectory)
            }
        }
        let live = try await bridge.capture(profile: profile, requireIndependentWindows: true)
        let liveNames = Set(live.flatMap(\.groups).map(\.title))
        let nativeWindows = try await catalog.windows(bundleID: "com.google.Chrome")
        let profileWindows = live.compactMap { try? catalog.chromeWindow($0, among: nativeWindows) }
        var canCreate: [Int] = []
        for group in snapshot.groups where !liveNames.contains(group.title) {
            if let button = catalog.savedGroupButton(group.title, windows: profileWindows) {
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    throw WorkspaceError.message("请在 Chrome 中打开已保存群组“\(group.title)”后重试。")
                }
                try await waitFor(timeout: 20, failure: "打开 Chrome 已保存群组“\(group.title)”超时，请在 Chrome 中打开该群组后重试。") {
                    let windows = try await self.bridge.capture(profile: profile)
                    return windows.flatMap(\.groups).contains(where: { $0.title == group.title }) ? true : nil
                }
            } else if group.saved == true {
                throw WorkspaceError.message("未找到已保存群组“\(group.title)”入口，请在 Chrome 中打开该群组后重试。")
            } else { canCreate.append(group.id) }
        }
        let restored = try await bridge.restore(entry, profile: profile, canCreateGroups: canCreate, sceneWindowIDs: sceneWindowIDs)
        return (profile, restored)
    }

    /// WebStorm 始终按真实项目目录恢复；普通应用只在窗口能唯一识别时调整。
    private func restoreApplication(_ entry: WorkspaceWindow) async throws -> WorkspaceNativeWindow {
        if let path = entry.projectPath, !FileManager.default.fileExists(atPath: path) {
            throw WorkspaceError.message("项目文件夹不存在：\(path)")
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else {
            throw WorkspaceError.message("找不到应用 \(entry.appName)。")
        }
        if let existing = try await matchingApplication(entry) { return existing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        if let path = entry.projectPath {
            // 交由 LaunchServices 打开项目，让 IDE 及其插件拥有自己的 TCC 身份。
            // 直接启动 webstorm 可执行文件会让 Qoder 等长期子进程继承本 App 的权限归属；
            // App 更新后旧、新签名会交替请求文稿权限，即使恢复结束也会不断弹窗。
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)],
                withApplicationAt: applicationURL, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        }
        return try await waitFor(timeout: 60, failure: "等待\(entry.label)窗口启动超时，请确认应用已完成加载后重试。") {
            try await self.matchingApplication(entry)
        }
    }

    private func matchingApplication(_ entry: WorkspaceWindow) async throws -> WorkspaceNativeWindow? {
        let windows = try await catalog.windows(bundleID: entry.bundleID)
        if let path = entry.projectPath {
            let matches = windows.filter { catalog.projectPath(for: $0) == path }
            guard matches.count < 2 else { throw WorkspaceError.message("同一 WebStorm 项目存在多个窗口，请保留一个明确目标。") }
            return matches.first
        }
        let named = windows.filter { $0.title == entry.title }
        if named.count == 1 { return named[0] }
        if windows.count == 1 { return windows[0] }
        if windows.count > 1 { throw WorkspaceError.message("\(entry.appName)有多个窗口，无法确定要恢复的窗口。") }
        return nil
    }

    /// 等待以实际状态为条件，不重复启动窗口；调用方提供阶段文案，避免把所有超时归因为应用弹窗。
    @discardableResult
    private func waitFor<T>(timeout: TimeInterval, failure: String, operation: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try await operation() { return value }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw WorkspaceError.message(failure)
    }
}
