import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// 使用临时模板和注入的桌面拓扑验证独立保存、选择范围与并发，不打开真实应用或创建桌面。
struct WorkspaceDesktopWorkflowTests {
    private func desktop(_ ordinal: Int, display: String = "screen-a") -> WorkspaceDesktop {
        WorkspaceDesktop(id: "old-\(display)-\(ordinal)", displayID: display, ordinal: ordinal,
            spaceID: UInt64(ordinal), screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    private func entry(_ ordinal: Int, title: String = "项目") -> WorkspaceWindow {
        WorkspaceWindow(bundleID: "com.jetbrains.WebStorm", appName: "WebStorm", title: title,
            desktop: desktop(ordinal), relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), projectPath: "/tmp/\(title)")
    }

    @Test func savingDesktopSevenPreservesOtherSavedAndDraftDesktops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSceneStore(file: root.appendingPathComponent("scene.json"))
        let savedThree = entry(3, title: "保存的项目")
        let draftFive = entry(5, title: "尚未保存")
        let draftSeven = entry(7, title: "新桌面")
        var library = WorkspaceSceneDrafts(saved: WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [savedThree]))
        library.drafts[desktop(5).selectionKey] = WorkspaceDesktopDraft(desktop: desktop(5), windows: [draftFive])
        library.drafts[desktop(7).selectionKey] = WorkspaceDesktopDraft(desktop: desktop(7), windows: [draftSeven])
        try library.save(desktop(7).selectionKey, to: store)
        #expect(try store.load()?.windows.map(\.id) == [savedThree.id, draftSeven.id])
        #expect(library.drafts[desktop(5).selectionKey]?.windows.first?.id == draftFive.id)
        #expect(library.drafts[desktop(7).selectionKey] == nil)
        #expect(library.restorationEntries(for: [desktop(7).selectionKey]).map(\.id) == [draftSeven.id])
    }

    @Test func restoreUsesSavedVersionAndOnlySelectedFailures() {
        let three = entry(3)
        let five = entry(5)
        var library = WorkspaceSceneDrafts(saved: WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [three, five]))
        library.drafts[desktop(3).selectionKey] = WorkspaceDesktopDraft(desktop: desktop(3), windows: [entry(3, title: "草稿")])
        #expect(library.restorationEntries(for: [desktop(3).selectionKey]).map(\.id) == [three.id])
        #expect(library.restorationEntries(for: [desktop(3).selectionKey], failedIDs: [five.id]).isEmpty)
        #expect(library.restorationEntries(for: [desktop(5).selectionKey], failedIDs: [five.id]).map(\.id) == [five.id])
    }

    @Test func emptyDesktopAndLegacySnapshotRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSceneStore(file: root.appendingPathComponent("scene.json"))
        let old = WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [entry(3)])
        let decoded = try JSONDecoder().decode(WorkspaceScene.self, from: JSONEncoder().encode(old))
        #expect(decoded.desktops == nil)
        #expect(decoded.savedDesktops.map(\.ordinal) == [3])
        var library = WorkspaceSceneDrafts(saved: decoded)
        library.drafts[desktop(3).selectionKey] = WorkspaceDesktopDraft(desktop: desktop(3), windows: [])
        try library.save(desktop(3).selectionKey, to: store)
        #expect(try store.load()?.windows.isEmpty == true)
        #expect(try store.load()?.savedDesktops.map(\.ordinal) == [3])
    }

    @Test func incompleteDesktopAndWriteFailureKeepDraftAndSavedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSceneStore(file: root.appendingPathComponent("scene.json"))
        let old = WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [entry(3)])
        try store.save(old)
        let bytes = try Data(contentsOf: store.file)
        var library = WorkspaceSceneDrafts(saved: old)
        var incomplete = entry(3)
        incomplete.issues = ["需要选择项目文件夹"]
        library.drafts[desktop(3).selectionKey] = WorkspaceDesktopDraft(desktop: desktop(3), windows: [incomplete])
        #expect(throws: WorkspaceError.self) { try library.save(desktop(3).selectionKey, to: store) }
        #expect(try Data(contentsOf: store.file) == bytes)
        #expect(library.drafts[desktop(3).selectionKey] != nil)
        library.drafts[desktop(3).selectionKey]?.windows[0].issues = []
        let invalidStore = WorkspaceSceneStore(file: store.file.appendingPathComponent("nested.json"))
        #expect(throws: (any Error).self) { try library.save(desktop(3).selectionKey, to: invalidStore) }
        #expect(library.saved?.windows.first?.id == old.windows.first?.id)
        #expect(library.drafts[desktop(3).selectionKey] != nil)
    }

    @Test func rebindMovesWholeDesktopAndKeepsTargetWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSceneStore(file: root.appendingPathComponent("scene.json"))
        let three = entry(3)
        let five = entry(5)
        var library = WorkspaceSceneDrafts(saved: WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [three, five]))
        try library.rebind(desktop(3), to: desktop(5), store: store)
        #expect(library.saved?.savedDesktops.map(\.ordinal) == [5])
        #expect(library.saved?.windows.map(\.id) == [three.id, five.id])
        #expect(library.saved?.windows.allSatisfy { $0.desktop.ordinal == 5 } == true)
    }

    @Test @MainActor func preparationAddsOnlyMissingDesktopsAndIsIdempotent() async throws {
        var topology = [desktop(1), desktop(2)]
        var additions = 0
        let add: (String) async throws -> Void = { displayID in
            additions += 1
            var next = desktop(topology.count + 1, display: displayID)
            next.id = "created-\(additions)"
            topology.append(next)
        }
        let result = await WorkspaceDesktopPreparation.prepare([desktop(3), desktop(5)], read: { topology }, add: add)
        #expect(additions == 3)
        #expect(try result[desktop(5).selectionKey]?.get().ordinal == 5)
        _ = await WorkspaceDesktopPreparation.prepare([desktop(3), desktop(5)], read: { topology }, add: add)
        #expect(additions == 3)
    }

    @Test @MainActor func failedCreationKeepsExistingTargetsAndDoesNotLoop() async throws {
        let topology = [desktop(1), desktop(2)]
        var attempts = 0
        let result = await WorkspaceDesktopPreparation.prepare([desktop(1), desktop(3)], read: { topology }, add: { _ in attempts += 1 })
        #expect(attempts == 1)
        #expect(try result[desktop(1).selectionKey]?.get().ordinal == 1)
        #expect(throws: (any Error).self) { try result[desktop(3).selectionKey]?.get() }
    }

    @Test @MainActor func missingDisplayAndUnreachableOrdinalDoNotCreate() async throws {
        let topology = [desktop(1), desktop(2, display: "screen-b")]
        let wrongNumber = desktop(1, display: "screen-b")
        let missingScreen = desktop(5, display: "gone")
        var attempts = 0
        let result = await WorkspaceDesktopPreparation.prepare([wrongNumber, missingScreen], read: { topology }, add: { _ in attempts += 1 })
        #expect(attempts == 0)
        #expect(throws: (any Error).self) { try result[wrongNumber.selectionKey]?.get() }
        #expect(throws: (any Error).self) { try result[missingScreen.selectionKey]?.get() }
    }

    @Test @MainActor func displaysResolveAfterEarlierDisplayAddsDesktops() async throws {
        var counts = [2, 1]
        let topology: () -> [WorkspaceDesktop] = {
            (1...counts[0]).map { desktop($0) } + (1...counts[1]).map { desktop(counts[0] + $0, display: "screen-b") }
        }
        let requested = [desktop(3), desktop(5, display: "screen-b")]
        let result = await WorkspaceDesktopPreparation.prepare(requested, read: topology, add: { displayID in
            counts[displayID == "screen-a" ? 0 : 1] += 1
        })
        #expect(counts == [3, 2])
        #expect(try result[requested[0].selectionKey]?.get().ordinal == 3)
        #expect(try result[requested[1].selectionKey]?.get().ordinal == 5)
    }

    @Test @MainActor func concurrentRestoreIsBoundedAndFailureDoesNotCancelOthers() async {
        let entries = (1...8).map { ordinal in
            var window = entry(ordinal)
            window.bundleID = "test.independent-app"
            return window
        }
        var active = 0
        var peak = 0
        var finished: [String] = []
        let result = await WorkspaceRestoreScheduler.run(entries, limit: 3, operation: { entry in
            active += 1
            peak = max(peak, active)
            try? await Task.sleep(nanoseconds: UInt64(9 - entry.desktop.ordinal) * 1_000_000)
            active -= 1
            return WorkspaceOutcome(windowID: entry.id, label: entry.label, error: entry.desktop.ordinal == 2 ? "模拟单项失败" : nil)
        }, finished: { finished.append($0.windowID) })
        #expect(peak == 3)
        #expect(active == 0)
        #expect(finished.count == 8)
        #expect(result.map(\.windowID) == entries.map(\.id))
        #expect(result.filter { $0.error != nil }.count == 1)
    }

    /// 多个 IDE 项目必须依次完成；失败释放串行位置，Chrome 在等待期间仍可启动。
    @Test @MainActor func webStormRestoresSeriallyAndOtherAppsCanProceed() async {
        var browser = entry(4)
        browser.bundleID = "com.google.Chrome"
        let entries = [entry(1), entry(2), entry(3), browser]
        var activeIDE = 0
        var idePeak = 0
        var browserOverlapped = false
        var opened: [String] = []
        let results = await WorkspaceRestoreScheduler.run(entries, operation: { window in
            let ide = window.bundleID == "com.jetbrains.WebStorm"
            if ide { activeIDE += 1; idePeak = max(idePeak, activeIDE); opened.append(window.id) }
            else { browserOverlapped = activeIDE > 0 }
            try? await Task.sleep(nanoseconds: 2_000_000)
            if ide { activeIDE -= 1 }
            return WorkspaceOutcome(windowID: window.id, label: window.label, error: window.id == entries[1].id ? "模拟打开失败" : nil)
        }, finished: { _ in })
        #expect(idePeak == 1)
        #expect(browserOverlapped)
        #expect(opened == Array(entries.prefix(3)).map(\.id))
        #expect(results.count == 4)
        #expect(results.filter { $0.error != nil }.count == 1)
    }

    /// 缺项提示必须包含每个窗口和对应修复方式；补齐一个项目后只清除此窗口的项目缺项。
    @Test @MainActor func missingInformationNamesEachWindowAndClearsWhenCorrected() {
        let controller = WorkspaceSceneController()
        var first = entry(3, title: "alpha")
        first.projectPath = nil
        first.issues = ["缺少项目路径，请选择项目文件夹。"]
        var second = entry(3, title: "beta")
        second.issues = ["未能读取窗口属性，请重新采集。"]
        let key = first.desktop.selectionKey
        controller.library.drafts[key] = WorkspaceDesktopDraft(desktop: first.desktop, windows: [first, second])
        let issues = controller.library.issues(for: key)
        #expect(issues.count == 2)
        #expect(issues[0].contains("alpha") && issues[0].contains("选择项目文件夹"))
        #expect(issues[1].contains("beta") && issues[1].contains("重新采集"))
        controller.updateProject(first, path: "/tmp/alpha")
        #expect(controller.library.issues(for: key).count == 1)
        #expect(controller.library.windows(for: key)[0].issues.isEmpty)
        #expect(controller.activity(for: first.desktop).failed)
    }

    @Test @MainActor func chromeResourceGateSerializesOnlySharedMutation() async {
        let gate = WorkspaceOperationGate()
        var active = 0
        var peak = 0
        let entries = (1...5).map { entry($0) }
        _ = await WorkspaceRestoreScheduler.run(entries, operation: { entry in
            await gate.acquire()
            active += 1
            peak = max(peak, active)
            try? await Task.sleep(nanoseconds: 1_000_000)
            active -= 1
            gate.release()
            return WorkspaceOutcome(windowID: entry.id, label: entry.label)
        }, finished: { _ in })
        #expect(peak == 1)
        #expect(active == 0)
    }

    @Test @MainActor func nonexistentProjectFailsBeforeOpeningApplication() async {
        var missing = entry(3)
        missing.projectPath = "/missing-workspace-test-\(UUID().uuidString)"
        let runner = WorkspaceRestoreRunner(catalog: WorkspaceWindowCatalog(), bridge: WorkspaceChromeBridge())
        let scene = WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [missing])
        let result = await runner.restore(missing, target: .success(desktop(3)), scene: scene)
        #expect(result.error?.contains("项目文件夹不存在") == true)
    }
}
