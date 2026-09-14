import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// 验证查看详情、复选框和业务按钮的事件隔离，不操作真实桌面。
@MainActor
struct WorkspaceSceneCardTests {
    @Test func rowLabelsFocusWhileCheckboxAndActionsRemainIndependent() throws {
        let card = WorkspaceDesktopCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 90))
        let container = NSView(frame: card.frame)
        container.addSubview(card)
        var toggles = 0
        var captures = 0
        var focused = 0
        card.onToggle = { toggles += 1 }
        card.onFocus = { focused += 1 }
        card.onCapture = { captures += 1 }
        card.layout()
        // hitTest 接收父视图坐标，卡片自身采用向下的 y 轴；测试须走实际坐标转换。
        let hit: (NSPoint) -> NSView? = { card.hitTest(card.convert($0, to: container)) }
        for point in [NSPoint(x: 100, y: 35), NSPoint(x: 300, y: 68), NSPoint(x: 550, y: 25)] {
            #expect(hit(point) === card)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            hit(point)?.mouseDown(with: event)
        }
        #expect(focused == 3)
        #expect(toggles == 0)
        let action = try #require(hit(NSPoint(x: 680, y: 57)) as? NSButton)
        action.performClick(nil)
        #expect(captures == 1)
        #expect(toggles == 0)
        let checkbox = try #require(hit(NSPoint(x: 23, y: 45)) as? NSButton)
        checkbox.performClick(nil)
        #expect(toggles == 1)
        #expect(focused == 3)
    }

    @Test func runningRowDoesNotChangeSelection() throws {
        let card = WorkspaceDesktopCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 90))
        let desktop = WorkspaceDesktop(id: "demo", displayID: "display", ordinal: 3, spaceID: 3,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var toggles = 0
        var focused = 0
        card.onToggle = { toggles += 1 }
        card.onFocus = { focused += 1 }
        card.configure(desktop: desktop, windows: [], displayName: "显示器", saved: true, draft: false, selected: true,
            activity: WorkspaceDesktopActivity(message: "恢复中…", running: true), busy: true,
            canCapture: false, canSave: false, canRestore: false)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 30),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        card.mouseDown(with: event)
        #expect(toggles == 0)
        #expect(focused == 1)
        card.configure(desktop: desktop, windows: [], displayName: "显示器", saved: true, draft: false, selected: true,
            activity: WorkspaceDesktopActivity(message: "已恢复"), busy: false,
            canCapture: true, canSave: false, canRestore: true)
        card.mouseDown(with: event)
        #expect(toggles == 0)
        #expect(focused == 2)
    }

    /// 混合结果按窗口编号显示；新缺项和重试清空结果都不能残留旧的绿色成功状态。
    @Test func windowResultsAndTabsKeepIndependentIdentities() throws {
        let desktop = WorkspaceDesktop(id: "demo", displayID: "display", ordinal: 3, spaceID: 3,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let first = WorkspaceWindow(bundleID: "com.jetbrains.WebStorm", appName: "WebStorm", title: "alpha",
            desktop: desktop, relativeFrame: .zero, projectPath: "/tmp/alpha")
        var second = WorkspaceWindow(bundleID: "com.jetbrains.WebStorm", appName: "WebStorm", title: "beta",
            desktop: desktop, relativeFrame: .zero, projectPath: "/tmp/beta")
        let success = WorkspaceOutcome(windowID: first.id, label: first.label)
        let failure = WorkspaceOutcome(windowID: second.id, label: second.label, error: "窗口启动超时")
        let items = [WorkspaceWindowPresentation(first, outcome: success), WorkspaceWindowPresentation(second, outcome: failure)]
        #expect(items.map(\.state) == [.succeeded, .failed])
        #expect(WorkspaceWindowPresentation(second, outcome: success).state == .normal)
        #expect(WorkspaceWindowPresentation(first, outcome: nil).state == .normal)
        second.issues = ["缺少项目路径，请选择项目文件夹。"]
        #expect(WorkspaceWindowPresentation(second, outcome: failure).state == .incomplete)

        let tabs = WorkspaceWindowTabsView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        var selected = first.id
        tabs.onSelect = { selected = $0; tabs.configure(items, selectedID: selected) }
        tabs.configure(items, selectedID: selected)
        let buttons = try #require(tabs.documentView?.subviews.compactMap { $0 as? NSButton })
        #expect(buttons.count == 2)
        buttons[1].performClick(nil)
        #expect(selected == second.id)
        #expect(buttons[1].state == .on)
        #expect(buttons[0].state == .off)
    }
}
