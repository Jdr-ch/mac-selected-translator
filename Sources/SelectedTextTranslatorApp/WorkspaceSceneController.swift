import AppKit

/// 桌面行只显示当前阶段，不将窗口完成数量当作真实进度百分比。
struct WorkspaceDesktopActivity {
    var message: String
    var running = false
    var failed = false
}

/// 管理桌面选择、独立草稿和执行状态；窗口展示层不直接修改保存模板。
@MainActor
final class WorkspaceSceneController {
    let catalog = WorkspaceWindowCatalog()
    let bridge = WorkspaceChromeBridge()
    let store: WorkspaceSceneStore
    var library = WorkspaceSceneDrafts()
    private(set) var currentDesktops: [WorkspaceDesktop] = []
    /// 以显示器与桌面名称保存本次面板选择；首次加载默认勾选全部已保存桌面。
    var selectedKeys: Set<String> = []
    private(set) var activities: [String: WorkspaceDesktopActivity] = [:]
    private(set) var outcomes: [WorkspaceOutcome] = []
    /// 仅恢复失败进入重试范围，采集和保存错误不能被误当作可重试的恢复结果。
    private var retryDesktopKeys: Set<String> = []
    private(set) var busy = false
    var status = "勾选需要的桌面，采集并检查窗口后单独保存。"
    var onChange: (() -> Void)?

    init(store: WorkspaceSceneStore = WorkspaceSceneStore()) { self.store = store }

    /// 已删除的保存桌面仍保留在清单中；新建桌面立即可选，不会改变已有勾选。
    var desktops: [WorkspaceDesktop] {
        var seen: Set<String> = []
        return (currentDesktops + library.drafts.values.map(\.desktop) + (library.saved?.savedDesktops ?? []))
            .filter { seen.insert($0.selectionKey).inserted }
            .sorted { $0.ordinal == $1.ordinal ? $0.displayID < $1.displayID : $0.ordinal < $1.ordinal }
    }

    var savedKeys: Set<String> { Set(library.saved?.savedDesktops.map(\.selectionKey) ?? []) }
    var failedKeys: Set<String> { retryDesktopKeys }

    /// 只在首次打开时加载模板；错误不会以空场景覆盖用户已经保存的数据。
    func load() {
        do {
            library.saved = try store.load()
            selectedKeys = savedKeys
            if let saved = library.saved { status = "已保存 \(saved.savedDesktops.count) 个桌面、\(saved.windows.count) 个窗口。" }
        } catch { status = error.localizedDescription }
        refreshDesktops()
    }

    /// 打开面板或点击刷新时读取桌面清单，捕获用户新增或删除桌面后的名称变化。
    func refreshDesktops() {
        guard !busy else { return }
        do {
            currentDesktops = try catalog.desktop.desktops()
            selectedKeys.formIntersection(Set(desktops.map(\.selectionKey)))
        }
        catch { status = error.localizedDescription }
        onChange?()
    }

    func activity(for desktop: WorkspaceDesktop) -> WorkspaceDesktopActivity {
        let key = desktop.selectionKey
        if let activity = activities[key] { return activity }
        if library.drafts[key] != nil { return WorkspaceDesktopActivity(message: "待保存") }
        if savedKeys.contains(key) {
            return WorkspaceDesktopActivity(message: currentDesktops.contains(where: { $0.selectionKey == key }) ? "已保存" : "恢复时补建／重绑")
        }
        return WorkspaceDesktopActivity(message: "尚未采集")
    }

    func canCapture(_ key: String) -> Bool { !busy && currentDesktops.contains { $0.selectionKey == key } }
    func canSave(_ key: String) -> Bool { !busy && library.drafts[key] != nil }
    func canRestore(_ key: String) -> Bool { !busy && savedKeys.contains(key) }

    /// 一次读取跨桌面窗口，结果按所选桌面分别更新草稿；其他桌面的草稿和模板保持原样。
    func capture(keys: Set<String>? = nil) async {
        guard !busy else { return }
        let requested = keys ?? selectedKeys
        guard !requested.isEmpty else { return }
        busy = true
        for key in requested { activities[key] = WorkspaceDesktopActivity(message: "采集中…", running: true) }
        status = "正在采集所选桌面的项目与群组…"
        onChange?()
        defer { busy = false; onChange?() }
        do {
            currentDesktops = try catalog.desktop.desktops()
            let targets = currentDesktops.filter { requested.contains($0.selectionKey) }
            let targetKeys = Set(targets.map(\.selectionKey))
            for key in requested.subtracting(targetKeys) {
                activities[key] = WorkspaceDesktopActivity(message: "桌面不存在，请先新建或重新绑定", failed: true)
            }
            guard !targets.isEmpty else { status = "所选桌面不存在，请刷新桌面清单。"; return }
            let nativeWindows = try await catalog.windows()
            let unresolved = catalog.unresolved
            let spaces = Set(targets.map(\.spaceID))
            let hasChrome = nativeWindows.contains { $0.bundleID == "com.google.Chrome" && !spaces.isDisjoint(with: $0.spaceIDs) }
            var profile = ""
            var directory = ""
            var chromeError: String?
            var chromeByNative: [UInt32: ChromeWindowSnapshot] = [:]
            if hasChrome {
                do {
                    let profiles = bridge.connectedProfiles()
                    guard profiles.count == 1, let connected = profiles.first else {
                        throw WorkspaceError.message("请只在要保存的 Chrome 资料中启用工作场景助手，然后重新采集。")
                    }
                    profile = connected
                    directory = try bridge.installedProfileDirectory()
                    let snapshots = try await bridge.capture(profile: profile)
                    // Chrome 匹配必须使用所有桌面的候选，不能因只勾选一个桌面而错误匹配同名窗口。
                    for var chrome in snapshots {
                        guard let native = try? catalog.chromeWindow(chrome, among: nativeWindows) else { continue }
                        for index in chrome.groups.indices {
                            chrome.groups[index].saved = catalog.savedGroupButton(chrome.groups[index].title, windows: [native]) != nil
                        }
                        chromeByNative[native.id] = chrome
                    }
                } catch { chromeError = error.localizedDescription }
            }
            for desktop in targets {
                var entries: [WorkspaceWindow] = []
                for native in nativeWindows where native.spaceIDs == [desktop.spaceID] {
                    var entry = WorkspaceWindow(bundleID: native.bundleID, appName: native.appName, title: native.title,
                        desktop: desktop, relativeFrame: WorkspaceGeometry.relative(native.frame, in: desktop.screenFrame))
                    if native.bundleID == "com.jetbrains.WebStorm" {
                        entry.projectPath = catalog.projectPath(for: native)
                        if entry.projectPath == nil { entry.issues.append("需要选择 WebStorm 项目文件夹。") }
                    } else if native.bundleID == "com.google.Chrome" {
                        entry.chrome = chromeByNative[native.id]
                        if entry.chrome == nil { entry.issues.append(chromeError ?? "无法匹配 Chrome 窗口，请重新采集。") }
                        if entry.chrome?.groups.contains(where: { $0.title.isEmpty }) == true {
                            entry.issues.append("请为未命名群组命名后重新采集。")
                        }
                    }
                    entries.append(entry)
                }
                for surface in unresolved where surface.spaceIDs == [desktop.spaceID] {
                    entries.append(WorkspaceWindow(bundleID: surface.bundleID, appName: surface.appName, title: surface.title,
                        desktop: desktop, relativeFrame: WorkspaceGeometry.relative(surface.frame, in: desktop.screenFrame),
                        issues: ["该窗口暂未读取完成，请再次采集；仍失败时检查应用是否有待处理弹窗。"]))
                }
                let key = desktop.selectionKey
                library.drafts[key] = WorkspaceDesktopDraft(desktop: desktop, windows: entries,
                    profileToken: profile, profileDirectory: directory)
                let incomplete = entries.contains { !$0.issues.isEmpty }
                activities[key] = WorkspaceDesktopActivity(message: incomplete ? "有待补充条目" : "已采集 · 待保存", failed: incomplete)
                let ids = Set(library.saved?.windows.filter { $0.desktop.selectionKey == key }.map(\.id) ?? [])
                outcomes.removeAll { ids.contains($0.windowID) }
                retryDesktopKeys.remove(key)
            }
            status = "已采集 \(targets.count) 个桌面。展开核对后，可逐桌面保存或保存所选。"
        } catch {
            for key in requested { activities[key] = WorkspaceDesktopActivity(message: error.localizedDescription, failed: true) }
            status = error.localizedDescription
        }
    }

    /// 所选桌面各自保存；某桌面有未补齐窗口时不阻止其他完整桌面保存。
    func save(keys: Set<String>? = nil) {
        guard !busy else { return }
        let requested = keys ?? selectedKeys
        var savedCount = 0
        var failedCount = 0
        for key in requested.sorted() where library.drafts[key] != nil {
            do {
                try library.save(key, to: store)
                activities[key] = WorkspaceDesktopActivity(message: "已保存")
                savedCount += 1
            } catch {
                activities[key] = WorkspaceDesktopActivity(message: error.localizedDescription, failed: true)
                failedCount += 1
            }
        }
        status = "已保存 \(savedCount) 个桌面" + (failedCount > 0 ? "，\(failedCount) 个桌面需要处理。" : "。")
        onChange?()
    }

    /// 只恢复勾选桌面的保存版本；集中补建后并发启动窗口，保留未勾选桌面的结果与草稿。
    func restore(keys: Set<String>? = nil, failedOnly: Bool = false) async {
        guard !busy, let scene = library.saved else { return }
        let requested = (keys ?? selectedKeys).intersection(savedKeys)
        let selected = failedOnly ? requested.intersection(failedKeys) : requested
        guard !selected.isEmpty else { return }
        let failedIDs = Set(outcomes.filter { $0.error != nil }.map(\.windowID))
        let entries = library.restorationEntries(for: selected, failedIDs: failedOnly ? failedIDs : nil)
        let targets = scene.savedDesktops.filter { selected.contains($0.selectionKey) }
        let entryIDs = Set(entries.map(\.id))
        outcomes.removeAll { entryIDs.contains($0.windowID) }
        busy = true
        for key in selected { activities[key] = WorkspaceDesktopActivity(message: "准备桌面…", running: true) }
        status = "正在准备所选桌面…"
        onChange?()
        defer { busy = false; onChange?() }
        let creation = WorkspaceDesktopCreation(desktop: catalog.desktop)
        let prepared = await WorkspaceDesktopPreparation.prepare(targets, read: { try self.catalog.desktop.desktops() },
            add: { try await creation.add(on: $0) }, progress: { displayID in
                for desktop in targets where desktop.displayID == displayID {
                    self.activities[desktop.selectionKey] = WorkspaceDesktopActivity(message: "正在补建桌面…", running: true)
                }
                self.onChange?()
            })
        await creation.finish()
        if let current = try? catalog.desktop.desktops() { currentDesktops = current }
        for desktop in targets {
            let key = desktop.selectionKey
            if entries.contains(where: { $0.desktop.selectionKey == key }) {
                activities[key] = WorkspaceDesktopActivity(message: "恢复中…", running: true)
            } else {
                do {
                    _ = try prepared[key]?.get()
                    activities[key] = WorkspaceDesktopActivity(message: "已恢复 · 无窗口需要打开")
                } catch { activities[key] = WorkspaceDesktopActivity(message: error.localizedDescription, failed: true) }
            }
        }
        status = "正在并行恢复窗口…"
        onChange?()
        let runner = WorkspaceRestoreRunner(catalog: catalog, bridge: bridge)
        let result = await WorkspaceRestoreScheduler.run(entries, operation: { entry in
            await runner.restore(entry, target: prepared[entry.desktop.selectionKey], scene: scene)
        }, finished: { outcome in
            self.outcomes.append(outcome)
            guard let entry = entries.first(where: { $0.id == outcome.windowID }) else { return }
            let key = entry.desktop.selectionKey
            let desktopIDs = Set(entries.filter { $0.desktop.selectionKey == key }.map(\.id))
            let completed = self.outcomes.filter { desktopIDs.contains($0.windowID) }
            if completed.count == desktopIDs.count {
                let failures = completed.filter { $0.error != nil }.count
                self.activities[key] = WorkspaceDesktopActivity(message: failures == 0 ? "已恢复并验证" : "\(failures) 项失败 · 可重试", failed: failures > 0)
            }
            self.onChange?()
        })
        // UI 结果顺序固定为模板顺序，避免并发完成次序让明细跳动。
        outcomes.sort { left, right in
            (scene.windows.firstIndex { $0.id == left.windowID } ?? 0) < (scene.windows.firstIndex { $0.id == right.windowID } ?? 0)
        }
        let failed = result.filter { $0.error != nil }.count
        let failures = Set(activities.filter { selected.contains($0.key) && $0.value.failed }.map(\.key))
        retryDesktopKeys.subtract(selected)
        retryDesktopKeys.formUnion(failures)
        let desktopFailures = failures.count
        status = desktopFailures == 0 ? "已恢复 \(selected.count) 个桌面、\(result.count) 个窗口。"
            : "已完成 \(result.count - failed) 个窗口，\(desktopFailures) 个桌面需要处理，可重试失败项。"
    }

    /// 项目修正与条目移除只更新所属桌面草稿，等待用户单独保存。
    func updateProject(_ entry: WorkspaceWindow, path: String) {
        library.edit(entry) { window in
            window.projectPath = path
            window.issues.removeAll { $0.contains("项目文件夹") }
        }
        activities.removeValue(forKey: entry.desktop.selectionKey)
        status = "项目已更新，请保存所属桌面。"
        onChange?()
    }

    func remove(_ entry: WorkspaceWindow) {
        library.remove(entry)
        activities.removeValue(forKey: entry.desktop.selectionKey)
        status = "已从草稿移除窗口，请保存所属桌面。"
        onChange?()
    }

    /// 重绑是明确确认的模板写入，不操作真实桌面；同时转移勾选并清理旧结果。
    func rebind(_ source: WorkspaceDesktop, to target: WorkspaceDesktop) {
        guard !busy else { return }
        do {
            try library.rebind(source, to: target, store: store)
            selectedKeys.remove(source.selectionKey)
            selectedKeys.insert(target.selectionKey)
            activities.removeValue(forKey: source.selectionKey)
            activities.removeValue(forKey: target.selectionKey)
            outcomes = []
            retryDesktopKeys = []
            status = "已重新绑定并保存到\(target.label)。"
        } catch { status = error.localizedDescription }
        onChange?()
    }
}
