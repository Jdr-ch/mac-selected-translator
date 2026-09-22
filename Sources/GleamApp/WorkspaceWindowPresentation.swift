import AppKit

/// 卡片标题与详情 tabs 共用逐窗口状态；采集缺项优先显示，不能被旧恢复成功结果遮盖。
struct WorkspaceWindowPresentation: Equatable {
    enum State: Equatable { case normal, incomplete, succeeded, failed }
    var id: String
    var title: String
    var state: State
    var explanation: String

    init(_ entry: WorkspaceWindow, outcome: WorkspaceOutcome?) {
        id = entry.id
        title = entry.label
        if !entry.issues.isEmpty {
            state = .incomplete
            explanation = "待补充：" + entry.issues.joined(separator: "；")
        } else if let outcome, outcome.windowID == entry.id {
            state = outcome.error == nil ? .succeeded : .failed
            explanation = outcome.error.map { "恢复失败：" + $0 } ?? "已恢复并验证"
        } else {
            state = .normal
            explanation = ""
        }
    }

    /// 颜色同时配合文字标识和完整提示，深色外观下仍保留结果可读性。
    var caption: String {
        switch state {
        case .normal: return title
        case .incomplete: return "⚠ " + title
        case .succeeded: return "✓ " + title
        case .failed: return "✕ " + title
        }
    }

    @MainActor var background: NSColor {
        switch state {
        case .normal: return WorkspaceScenePalette.chip
        case .incomplete: return WorkspaceScenePalette.warningBackground
        case .succeeded: return WorkspaceScenePalette.successBackground
        case .failed: return WorkspaceScenePalette.failureBackground
        }
    }

    @MainActor var foreground: NSColor {
        switch state {
        case .normal: return WorkspaceScenePalette.text
        case .incomplete: return WorkspaceScenePalette.warning
        case .succeeded: return WorkspaceScenePalette.success
        case .failed: return WorkspaceScenePalette.failure
        }
    }
}

/// 独立的原生按钮 tab 保留键盘切换能力；长窗口名称截断显示，悬停可读完整标题和结果。
@MainActor
private final class WorkspaceWindowTab: NSButton {
    var item: WorkspaceWindowPresentation? { didSet { needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let selected = state == .on
        (item.state == .normal && !selected ? WorkspaceScenePalette.content : item.background).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        (item.caption as NSString).draw(in: NSRect(x: 10, y: 9, width: bounds.width - 20, height: 17), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular),
            .foregroundColor: item.foreground, .paragraphStyle: paragraph
        ])
        if selected {
            WorkspaceScenePalette.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 1, width: bounds.width - 18, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// 详情使用横向可滚动 tabs，按窗口 ID 保留焦点，结果刷新不触发采集或修改勾选。
@MainActor
final class WorkspaceWindowTabsView: NSScrollView {
    private let content = NSView()
    private var buttons: [WorkspaceWindowTab] = []
    private var items: [WorkspaceWindowPresentation] = []
    private var selectedID: String?
    var onSelect: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        documentView = content
    }

    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }

    /// 只在窗口或结果变化时重建标题；用户切换 tab 只改变选中外观和可见范围。
    func configure(_ values: [WorkspaceWindowPresentation], selectedID: String?) {
        let changedSelection = self.selectedID != selectedID
        self.selectedID = selectedID
        if values != items {
            items = values
            buttons.forEach { $0.removeFromSuperview() }
            buttons = values.enumerated().map { index, item in
                let button = WorkspaceWindowTab(title: item.caption, target: self, action: #selector(selectTab(_:)))
                button.setButtonType(.radio)
                button.item = item
                button.tag = index
                button.isBordered = false
                button.toolTip = [item.title, item.explanation].filter { !$0.isEmpty }.joined(separator: "\n")
                button.setAccessibilityLabel(button.toolTip)
                content.addSubview(button)
                return button
            }
        }
        var x: CGFloat = 0
        for (button, item) in zip(buttons, values) {
            let width = min(300, max(100, ceil((item.caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 24))
            button.frame = NSRect(x: x, y: 0, width: width, height: 34)
            button.state = item.id == selectedID ? .on : .off
            x += width + 6
        }
        content.frame = NSRect(x: 0, y: 0, width: max(x, contentSize.width), height: 34)
        if changedSelection, let button = buttons.first(where: { $0.state == .on }) { content.scrollToVisible(button.frame) }
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect?(items[sender.tag].id)
    }
}
