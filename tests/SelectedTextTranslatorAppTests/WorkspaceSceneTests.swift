import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// 场景持久化、几何适配和桌面身份规则；真机探针仅在显式环境变量启用时运行。
struct WorkspaceSceneTests {
    private func desktop(id: String = "space-a", spaceID: UInt64 = 3) -> WorkspaceDesktop {
        WorkspaceDesktop(id: id, displayID: "display-a", ordinal: 3, spaceID: spaceID,
                         screenFrame: CGRect(x: -1680, y: 39, width: 1680, height: 1290))
    }

    @Test func geometryRoundTripAndScreenChange() {
        let screen = desktop().screenFrame
        let frame = CGRect(x: -840, y: 39, width: 840, height: 900)
        let relative = WorkspaceGeometry.relative(frame, in: screen)
        #expect(WorkspaceGeometry.absolute(relative, in: screen) == frame)
        let smaller = CGRect(x: 0, y: 24, width: 1000, height: 700)
        #expect(smaller.contains(WorkspaceGeometry.absolute(relative, in: smaller)))
    }

    @Test func desktopUUIDWinsOverRecycledNumericID() throws {
        let saved = desktop()
        let afterRestart = desktop(spaceID: 900)
        #expect(try WorkspaceGeometry.resolve(saved, in: [afterRestart]).spaceID == 900)
        #expect(throws: WorkspaceError.self) { try WorkspaceGeometry.resolve(saved, in: [desktop(id: "other")]) }
    }

    @Test func incompleteSavePreservesExistingScene() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSceneStore(file: root.appendingPathComponent("scene.json"))
        let entry = WorkspaceWindow(bundleID: "com.jetbrains.WebStorm", appName: "WebStorm", title: "sample",
            desktop: desktop(), relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), projectPath: "/tmp/sample")
        var scene = WorkspaceScene(profileToken: "profile", chromeProfileDirectory: "Default", windows: [entry])
        try store.save(scene)
        scene.windows[0].issues = ["项目路径待选择"]
        #expect(throws: WorkspaceError.self) { try store.save(scene) }
        #expect(try store.load()?.windows.first?.issues.isEmpty == true)
        #expect(try store.load()?.windows.first?.projectPath == "/tmp/sample")
    }

    @Test @MainActor func missingBridgeFailsWithoutWaiting() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bridge = WorkspaceChromeBridge(root: root)
        #expect(bridge.connectedProfiles().isEmpty)
        await #expect(throws: WorkspaceError.self) { try await bridge.capture(profile: UUID().uuidString) }
    }

    @Test @MainActor func nativeTitleCollisionDoesNotGuessWindow() throws {
        let catalog = WorkspaceWindowCatalog()
        let element = AXUIElementCreateSystemWide()
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windows = [UInt32(1), UInt32(2)].map {
            WorkspaceNativeWindow(id: $0, element: element, bundleID: "com.google.Chrome", appName: "Chrome", title: "相同标题", frame: frame, spaceIDs: [UInt64($0)])
        }
        let snapshot = ChromeWindowSnapshot(windowId: 99, left: 0, top: 0, width: 800, height: 600, state: "normal",
            tabs: [ChromeTabSnapshot(url: "https://example.com", title: "相同标题", pinned: false, active: true, groupId: -1)], groups: [])
        #expect(throws: WorkspaceError.self) { try catalog.chromeWindow(snapshot, among: windows) }
    }

    /// 必须移动另一个进程的窗口且目标不同于来源，防止自有窗口权限或直接返回造成假通过。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKSPACE_LIVE_TESTS"] == "1"))
    @MainActor func nativeDesktopMoveReadback() async throws {
        _ = NSApplication.shared
        let adapter = WorkspaceNativeDesktop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("window-id")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/workspace_native_window.swift")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        helper.arguments = [source.path, output.path]
        defer {
            if helper.isRunning { helper.terminate(); helper.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        try helper.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let id = try #require(UInt32(String(contentsOf: output, encoding: .utf8)))
        // 子进程公布编号后，WindowServer 仍需完成首次映射；等待实际空间出现再选择不同目标。
        var original: [UInt64] = []
        for _ in 0..<30 {
            original = try adapter.spaces(for: id)
            if !original.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let desktops = try adapter.desktops()
        print("测试窗口来源", original, "桌面映射", desktops.map { "\($0.ordinal)=\($0.spaceID)" })
        let sourceDesktop = try #require(desktops.first { original == [$0.spaceID] })
        let target = try #require(desktops.first { $0.displayID == sourceDesktop.displayID && !original.contains($0.spaceID) })
        print("跨进程窗口", id, "来源", original, "目标", target.spaceID)
        try await adapter.move(id, to: target)
        #expect(try adapter.spaces(for: id) == [target.spaceID])
        try await adapter.move(id, to: target)
        #expect(try adapter.spaces(for: id) == [target.spaceID])
        try await adapter.move(id, to: sourceDesktop)
        #expect(try adapter.spaces(for: id) == original)
    }

    /// 使用保存场景解析当前连接，再只读对照 Chrome 快照与系统窗口；不打开群组或改变用户窗口。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKSPACE_CHROME_LIVE_TESTS"] == "1"))
    @MainActor func chromeLiveWindowsMatchNativeCatalog() async throws {
        _ = NSApplication.shared
        let saved = try WorkspaceSceneStore().load()
        let scene = try #require(saved)
        let bridge = WorkspaceChromeBridge()
        let profiles = bridge.connectedProfiles()
        #expect(profiles.count == 1)
        let resolved = try bridge.restorationProfile(savedProfile: scene.profileToken, profileDirectory: scene.chromeProfileDirectory)
        let profile = try #require(resolved)
        #expect(profiles.contains(profile))
        print("保存资料连接仍有效", profile == scene.profileToken, "当前安装目录", try bridge.installedProfileDirectory())
        let snapshots = try await bridge.capture(profile: profile, requireIndependentWindows: true)
        let catalog = WorkspaceWindowCatalog()
        let native = try await catalog.windows(bundleID: "com.google.Chrome")
        for window in native { print("Native Chrome", window.id, window.title, window.frame, window.spaceIDs) }
        for window in snapshots { print("Extension Chrome", window.windowId, window.activeTitle, window.frame, window.groups.map(\.title)) }
        for snapshot in snapshots {
            let matched = try catalog.chromeWindow(snapshot, among: native)
            print("Matched", snapshot.windowId, matched.id)
        }
        for name in scene.windows.compactMap(\.chrome).flatMap(\.groups).map(\.title) {
            if let button = catalog.savedGroupButton(name, windows: native) {
                var actions: CFArray?
                AXUIElementCopyActionNames(button, &actions)
                print("Saved group", name, "role", WorkspaceWindowCatalog.read(button, kAXRoleAttribute) as String? ?? "",
                      "title", WorkspaceWindowCatalog.read(button, kAXTitleAttribute) as String? ?? "",
                      "description", WorkspaceWindowCatalog.read(button, kAXDescriptionAttribute) as String? ?? "",
                      "actions", actions as? [String] ?? [])
            }
        }
    }

    /// 只读对照 WindowServer 的全部桌面窗口与采集结果，不切换桌面或改变用户窗口。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKSPACE_CAPTURE_LIVE_TESTS"] == "1"))
    @MainActor func nativeCatalogAcrossSpaces() async throws {
        _ = NSApplication.shared
        let catalog = WorkspaceWindowCatalog()
        let desktops = try catalog.desktop.desktops()
        let targetSpaces = Set(desktops.filter { [3, 4, 5].contains($0.ordinal) }.map(\.spaceID))
        let actual = try await catalog.windows(in: targetSpaces)
        print("Desktop mapping:", desktops.map { "\($0.ordinal)=\($0.spaceID)" })
        for app in NSWorkspace.shared.runningApplications where ["com.google.Chrome", "com.jetbrains.WebStorm"].contains(app.bundleIdentifier ?? "") {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            let elements: [AXUIElement] = WorkspaceWindowCatalog.read(ax, kAXWindowsAttribute) ?? []
            print("AX", app.bundleIdentifier ?? "", "hidden", app.isHidden, "count", elements.count)
            for element in elements {
                let id = try catalog.desktop.id(of: element)
                let subrole: String = WorkspaceWindowCatalog.read(element, kAXSubroleAttribute) ?? "nil"
                print("AX window", id, subrole, "spaces", try catalog.desktop.spaces(for: id))
            }
        }
        let server = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var expected: Set<UInt32> = []
        for info in server where ["Google Chrome", "WebStorm"].contains(info[kCGWindowOwnerName as String] as? String ?? "") {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let id = number.uint32Value
            let spaces = try catalog.desktop.spaces(for: id)
            print("WindowServer", info[kCGWindowOwnerName as String] ?? "", id, "spaces", spaces)
            if !targetSpaces.isDisjoint(with: spaces) { expected.insert(id) }
        }
        print("Captured IDs:", actual.map(\.id))
        #expect(!expected.isEmpty)
        #expect(expected.isSubset(of: Set(actual.map(\.id))))
    }
}
