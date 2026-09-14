import AppKit
import ApplicationServices

/// 一个工作场景的编辑与执行状态；窗口控制器只展示此状态，不复制采集或恢复流程。
@MainActor
final class WorkspaceSceneController {
    let catalog = WorkspaceWindowCatalog()
    let bridge = WorkspaceChromeBridge()
    let store = WorkspaceSceneStore()
    var scene: WorkspaceScene?
    var outcomes: [WorkspaceOutcome] = []
    var busy = false
    /// 草稿修改后必须显式保存，恢复操作只接受用户已确认的模板。
    var isDirty = false
    var status = "先采集桌面 3、4、5，检查清单后保存。"
    var onChange: (() -> Void)?

    /// 打开管理面板时加载已有模板，读取失败不覆盖内存中的场景。
    func load() {
        do {
            if let saved = try store.load() {
                scene = saved
                isDirty = false
                status = "已保存 \(saved.windows.count) 个窗口，可直接恢复或重新采集。"
            }
        } catch { status = error.localizedDescription }
        onChange?()
    }

    /// 只采集所选普通桌面；从扩展获取完整 Chrome 窗口，再与原生空间归属关联。
    func capture() async {
        guard !busy else { return }
        busy = true
        status = "正在采集桌面 3、4、5…"
        onChange?()
        defer { busy = false; onChange?() }
        do {
            let desktops = try catalog.desktop.desktops().filter { [3, 4, 5].contains($0.ordinal) }
            guard desktops.count == 3 else { throw WorkspaceError.message("当前没有完整的桌面 3、4、5，请恢复桌面配置后采集。") }
            let profiles = bridge.connectedProfiles()
            guard profiles.count == 1, let profile = profiles.first else {
                throw WorkspaceError.message(profiles.isEmpty ? "请先在 Chrome 当前用户资料中启用工作场景助手。" : "有多个 Chrome 资料连接，请只在要保存的资料中启用扩展。")
            }
            let chromeWindows = try await bridge.capture(profile: profile)
            // Chrome 快照包含全部窗口，匹配时也使用全部桌面，避免把其他桌面同标题窗口误配到目标桌面。
            let nativeWindows = try await catalog.windows()
            var chromeByNative: [UInt32: ChromeWindowSnapshot] = [:]
            for var chrome in chromeWindows {
                guard let native = try? catalog.chromeWindow(chrome, among: nativeWindows) else { continue }
                for index in chrome.groups.indices {
                    chrome.groups[index].saved = catalog.savedGroupButton(chrome.groups[index].title, windows: [native]) != nil
                }
                chromeByNative[native.id] = chrome
            }
            var entries: [WorkspaceWindow] = []
            for native in nativeWindows {
                let matches = desktops.filter { native.spaceIDs.contains($0.spaceID) }
                guard matches.count == 1, let desktop = matches.first else { continue }
                var entry = WorkspaceWindow(bundleID: native.bundleID, appName: native.appName, title: native.title,
                    desktop: desktop, relativeFrame: WorkspaceGeometry.relative(native.frame, in: desktop.screenFrame))
                if native.bundleID == "com.jetbrains.WebStorm" {
                    entry.projectPath = catalog.projectPath(for: native)
                    if entry.projectPath == nil { entry.issues.append("需要选择 WebStorm 项目文件夹。") }
                } else if native.bundleID == "com.google.Chrome" {
                    entry.chrome = chromeByNative[native.id]
                    if entry.chrome == nil { entry.issues.append("无法匹配当前资料中的 Chrome 窗口，请检查资料或重新采集。") }
                    if entry.chrome?.groups.contains(where: { $0.title.isEmpty }) == true { entry.issues.append("请为未命名群组命名后重新采集。") }
                }
                entries.append(entry)
            }
            // 系统已确认存在但尚未响应 AX 的窗口仍显示在预览中，不静默保存一个桌面子集。
            for surface in catalog.unresolved {
                let matches = desktops.filter { surface.spaceIDs.contains($0.spaceID) }
                guard matches.count == 1, let desktop = matches.first else { continue }
                entries.append(WorkspaceWindow(bundleID: surface.bundleID, appName: surface.appName, title: surface.title,
                    desktop: desktop, relativeFrame: WorkspaceGeometry.relative(surface.frame, in: desktop.screenFrame),
                    issues: ["该桌面窗口暂未读取完成，请再次采集；仍失败时检查应用是否有待处理弹窗。"]))
            }
            guard !entries.isEmpty else { throw WorkspaceError.message("目标桌面没有可采集的普通窗口。") }
            let directory = try bridge.installedProfileDirectory()
            scene = WorkspaceScene(profileToken: profile, chromeProfileDirectory: directory,
                                   windows: entries.sorted { $0.desktop.ordinal < $1.desktop.ordinal })
            isDirty = true
            outcomes = []
            let counts = desktops.map { desktop in "\(desktop.label)：\(entries.filter { $0.desktop.id == desktop.id }.count)" }.joined(separator: "，")
            status = "已采集 \(entries.count) 个窗口（\(counts)）。请检查清单后保存。"
        } catch { status = error.localizedDescription }
    }

    /// 保存只接受完整预览；用户修正项目和桌面后统一持久化，避免半完成模板覆盖旧模板。
    func save() {
        guard !busy, var scene else { return }
        do {
            scene.savedAt = Date()
            try store.save(scene)
            self.scene = scene
            isDirty = false
            status = "工作场景已保存，共 \(scene.windows.count) 个窗口。"
        } catch { status = error.localizedDescription }
        onChange?()
    }

    /// 仅重试失败条目时使用上次结果；运行中禁止再次提交，结束后总会释放 busy。
    func restore(failedOnly: Bool = false) async {
        guard !busy else { return }
        guard !isDirty else { status = "请先保存当前场景修改，再恢复窗口。"; onChange?(); return }
        if scene == nil { load() }
        guard let scene else { status = "请先保存工作场景。"; onChange?(); return }
        let failedIDs = Set(outcomes.filter { $0.error != nil }.map(\.windowID))
        let entries = scene.windows.filter { !failedOnly || failedIDs.contains($0.id) }
        guard !entries.isEmpty else { return }
        busy = true
        outcomes.removeAll { outcome in entries.contains(where: { $0.id == outcome.windowID }) }
        onChange?()
        defer { busy = false; onChange?() }
        let chromeWindowIDs = scene.windows.filter { $0.chrome != nil }.map(\.id)
        // 同次恢复中，一个原生窗口只能对应一个模板条目；防止后续条目覆盖已恢复布局。
        var assignedWindowIDs: Set<UInt32> = []
        for (index, entry) in entries.enumerated() {
            status = "正在恢复 \(index + 1)/\(entries.count)：\(entry.label)"
            onChange?()
            do {
                guard entry.issues.isEmpty else { throw WorkspaceError.message(entry.issues.joined(separator: "；")) }
                let target = try WorkspaceGeometry.resolve(entry.desktop, in: catalog.desktop.desktops())
                let native: WorkspaceNativeWindow
                if entry.chrome != nil {
                    native = try await restoreChrome(entry, profile: scene.profileToken,
                        profileDirectory: scene.chromeProfileDirectory, sceneWindowIDs: chromeWindowIDs)
                } else {
                    native = try await restoreApplication(entry)
                }
                guard assignedWindowIDs.insert(native.id).inserted else {
                    throw WorkspaceError.message("该窗口已被本次其他场景条目使用，无法分别恢复，请检查窗口分配后重试。")
                }
                let frame = WorkspaceGeometry.absolute(entry.relativeFrame, in: target.screenFrame)
                // 先移入目标显示器，再指定该显示器的桌面，避免跨显示器恢复使用错误空间。
                try catalog.applyFrame(frame, to: native)
                try await catalog.desktop.move(native.id, to: target)
                try catalog.applyFrame(frame, to: native)
                // WindowServer 更新有短暂延迟；只有位置、尺寸和唯一桌面归属都吻合才报告成功。
                try await waitFor(timeout: 5, failure: "\(entry.label)的桌面或位置验证超时，请重试该条目。") { () async throws -> Bool? in
                    guard try self.catalog.desktop.spaces(for: native.id) == [target.spaceID],
                          let current = WorkspaceWindowCatalog.frame(native.element),
                          WorkspaceWindowCatalog.distance(current, frame) <= 8 else { return nil }
                    return true
                }
                outcomes.append(WorkspaceOutcome(windowID: entry.id, label: entry.label))
            } catch {
                outcomes.append(WorkspaceOutcome(windowID: entry.id, label: entry.label, error: error.localizedDescription))
            }
            onChange?()
        }
        let failed = outcomes.filter { $0.error != nil }.count
        status = failed == 0 ? "恢复完成：\(outcomes.count) 个窗口已回到目标桌面和位置。"
            : "已完成 \(outcomes.count - failed) 项，\(failed) 项需要处理，可重试失败项。"
    }

    /// 已保存但未打开的群组优先通过 Chrome 原生入口打开，防止创建重复的已保存群组。
    private func restoreChrome(_ entry: WorkspaceWindow, profile savedProfile: String, profileDirectory: String,
                               sceneWindowIDs: [String]) async throws -> WorkspaceNativeWindow {
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
        return try await waitFor(timeout: 30, failure: "Chrome 已返回恢复结果，但无法唯一匹配“\(entry.label)”的系统窗口，请重试该条目。") {
            let current = try await self.bridge.capture(profile: profile)
            // 本次响应的窗口编号仅在当前浏览器连接中使用，允许保留快照外的用户标签。
            guard let chrome = current.first(where: { $0.windowId == restored.windowId }) else { return nil }
            let native = try await self.catalog.windows(bundleID: "com.google.Chrome")
            return try? self.catalog.chromeWindow(chrome, among: native)
        }
    }

    /// WebStorm 始终按真实项目目录恢复；普通应用只在窗口能唯一识别时调整。
    private func restoreApplication(_ entry: WorkspaceWindow) async throws -> WorkspaceNativeWindow {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else {
            throw WorkspaceError.message("找不到应用 \(entry.appName)。")
        }
        if let path = entry.projectPath, !FileManager.default.fileExists(atPath: path) {
            throw WorkspaceError.message("项目文件夹不存在：\(path)")
        }
        if let existing = try await matchingApplication(entry) { return existing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        if let path = entry.projectPath {
            // WebStorm 只接收项目目录；--new-window 会被当成文件名并误开 LightEdit。
            let process = Process()
            process.executableURL = applicationURL.appendingPathComponent("Contents/MacOS/webstorm")
            process.arguments = [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
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
