import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// 只验证卡片事件路由：文字和空白勾选整行，业务按钮不串入勾选动作，不操作真实桌面。
@MainActor
struct WorkspaceSceneCardTests {
    @Test func rowLabelsToggleWhileActionButtonsRemainIndependent() throws {
        let card = WorkspaceDesktopCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 90))
        let container = NSView(frame: card.frame)
        container.addSubview(card)
        var toggles = 0
        var captures = 0
        card.onToggle = { toggles += 1 }
        card.onCapture = { captures += 1 }
        card.layout()
        // hitTest 接收父视图坐标，卡片自身采用向下的 y 轴；测试须走实际坐标转换。
        let hit: (NSPoint) -> NSView? = { card.hitTest(card.convert($0, to: container)) }
        for point in [NSPoint(x: 100, y: 35), NSPoint(x: 300, y: 68), NSPoint(x: 550, y: 25)] {
            #expect(hit(point) === card)
        }
        let action = try #require(hit(NSPoint(x: 680, y: 57)) as? NSButton)
        action.performClick(nil)
        #expect(captures == 1)
        #expect(toggles == 0)
        let checkbox = try #require(hit(NSPoint(x: 23, y: 45)) as? NSButton)
        checkbox.performClick(nil)
        #expect(toggles == 1)
    }

    @Test func runningRowDoesNotChangeSelection() throws {
        let card = WorkspaceDesktopCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 90))
        let desktop = WorkspaceDesktop(id: "demo", displayID: "display", ordinal: 3, spaceID: 3,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var toggles = 0
        card.onToggle = { toggles += 1 }
        card.configure(desktop: desktop, windows: [], displayName: "显示器", saved: true, draft: false, selected: true,
            activity: WorkspaceDesktopActivity(message: "恢复中…", running: true), busy: true,
            canCapture: false, canSave: false, canRestore: false)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 30),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        card.mouseDown(with: event)
        #expect(toggles == 0)
        card.configure(desktop: desktop, windows: [], displayName: "显示器", saved: true, draft: false, selected: true,
            activity: WorkspaceDesktopActivity(message: "已恢复"), busy: false,
            canCapture: true, canSave: false, canRestore: true)
        card.mouseDown(with: event)
        #expect(toggles == 1)
    }
}
