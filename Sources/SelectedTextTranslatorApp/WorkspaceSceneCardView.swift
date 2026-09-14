import AppKit

/// B 方案的颜色集中定义，浅色和深色均使用同一套层级与间距。
@MainActor
enum WorkspaceScenePalette {
    static let window = color(0xf5f5f7, 0x242426)
    static let content = color(0xffffff, 0x2e2e31)
    static let text = color(0x202124, 0xf0f0f2)
    static let secondary = color(0x65666c, 0xb2b2bb)
    static let line = color(0xdedee4, 0x46464c)
    static let accent = color(0x087aff, 0x65aaff)
    static let link = color(0x0864cb, 0x8abeff)
    static let chip = color(0xeeeef2, 0x38383e)
    static let success = color(0x248449, 0x83d8a2)
    static let warning = color(0x98640f, 0xefc77c)
    static let failure = color(0xb42332, 0xff9caa)
    static let successBackground = color(0xdff3e5, 0x224132)
    static let failureBackground = color(0xffe2e5, 0x512e37)
    static let warningBackground = color(0xffefcc, 0x4a3c25)

    private static func color(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

/// 保留原生按钮的键盘与无障碍行为，仅绘制设计稿中的圆角按钮或蓝色文字操作。
@MainActor
final class WorkspaceSceneButton: NSButton {
    enum Style { case secondary, primary, link }
    var style: Style = .secondary { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: style == .link ? 12 : 13)]).width
        return NSSize(width: ceil(width) + (style == .link ? 12 : 22), height: style == .link ? 26 : 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.75 : 1) : 0.42
        if style != .link {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            (style == .primary ? WorkspaceScenePalette.accent : WorkspaceScenePalette.content).withAlphaComponent(alpha).setFill()
            path.fill()
            (style == .primary ? WorkspaceScenePalette.accent : WorkspaceScenePalette.line).withAlphaComponent(alpha).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = style == .primary ? .white : (style == .link ? WorkspaceScenePalette.link : WorkspaceScenePalette.text)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: style == .link ? 12 : 13),
            .foregroundColor: color.withAlphaComponent(alpha)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// 卡片标题按窗口逐项着色并换行，完整原因同时通过悬停和下方 tabs 提供。
@MainActor
private final class WorkspaceSceneChips: NSView {
    private var labels: [NSTextField] = []
    private var items: [WorkspaceWindowPresentation] = []
    override var isFlipped: Bool { true }

    func configure(_ values: [WorkspaceWindowPresentation]) {
        guard items != values else { return }
        items = values
        for label in labels { label.removeFromSuperview() }
        labels = values.map { item in
            let label = NSTextField(labelWithString: item.caption)
            label.font = .systemFont(ofSize: 11)
            label.textColor = item.foreground
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = [item.title, item.explanation].filter { !$0.isEmpty }.joined(separator: "\n")
            addSubview(label)
            return label
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for label in labels {
            let width = chipWidth(label.stringValue, available: bounds.width)
            if x > 0, x + width > bounds.width { x = 0; y += 23 }
            label.frame = NSRect(x: x + 5, y: y + 3, width: max(width - 10, 0), height: 16)
            label.isHidden = y + 20 > bounds.height
            x += width + 5
        }
        needsDisplay = true
    }

    /// 以文字本身测量，不能读取已经受上一帧宽度限制的 intrinsicContentSize，否则标签会逐帧缩短。
    private func chipWidth(_ text: String, available: CGFloat) -> CGFloat {
        min(ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 14, available)
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        var used: CGFloat = 0
        var height: CGFloat = 22
        for item in items {
            let next = chipWidth(item.caption, available: width)
            if used > 0, used + next > width { height += 23; used = 0 }
            used += next + 5
        }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        for (label, item) in zip(labels, items) where !label.isHidden {
            item.background.setFill()
            NSBezierPath(roundedRect: label.frame.insetBy(dx: -5, dy: -2), xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// B 方案桌面卡片：左侧桌面及保存状态，中部项目摘要，右侧运行状态和独立操作。
@MainActor
final class WorkspaceDesktopCardView: NSView {
    private let background = WorkspaceDesktopRowView()
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chips = WorkspaceSceneChips()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let captureButton = WorkspaceSceneButton(title: "采集", target: nil, action: nil)
    private let saveButton = WorkspaceSceneButton(title: "保存", target: nil, action: nil)
    private let restoreButton = WorkspaceSceneButton(title: "恢复", target: nil, action: nil)
    private var enabled = true
    var onToggle: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCapture: (() -> Void)?
    var onSave: (() -> Void)?
    var onRestore: (() -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 90) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(background)
        for view in [checkbox, titleLabel, subtitleLabel, chips, countLabel, statusLabel, captureButton, saveButton, restoreButton] { addSubview(view) }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = WorkspaceScenePalette.text
        for label in [subtitleLabel, countLabel] { label.font = .systemFont(ofSize: 11); label.textColor = WorkspaceScenePalette.secondary }
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .right
        for label in [titleLabel, subtitleLabel, countLabel, statusLabel] { label.lineBreakMode = .byTruncatingTail }
        checkbox.target = self
        checkbox.action = #selector(toggle)
        for (button, action) in [(captureButton, #selector(capture)), (saveButton, #selector(save)), (restoreButton, #selector(restore))] {
            button.target = self
            button.action = action
            button.style = .link
            button.isBordered = false
        }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }

    /// 行显示依赖桌面快照与本次操作阶段，不在绘制或勾选时采集真实窗口。
    func configure(desktop: WorkspaceDesktop, windows: [WorkspaceWindow], displayName: String,
                   saved: Bool, draft: Bool, selected: Bool, activity: WorkspaceDesktopActivity,
                   busy: Bool, canCapture: Bool, canSave: Bool, canRestore: Bool, outcomes: [WorkspaceOutcome] = []) {
        enabled = !busy
        checkbox.state = selected ? .on : .off
        checkbox.isEnabled = !busy
        checkbox.setAccessibilityLabel("勾选\(desktop.label)")
        titleLabel.stringValue = desktop.label
        subtitleLabel.stringValue = displayName + " · " + (draft ? "待保存" : (saved ? "已保存" : "尚未保存"))
        subtitleLabel.toolTip = subtitleLabel.stringValue
        chips.configure(windows.map { entry in
            WorkspaceWindowPresentation(entry, outcome: outcomes.first { $0.windowID == entry.id })
        })
        let tabs = windows.compactMap(\.chrome).reduce(0) { $0 + $1.tabs.count }
        countLabel.stringValue = windows.isEmpty ? (saved || draft ? "空桌面 · 无窗口" : "尚未采集窗口")
            : "\(windows.count) 个窗口" + (tabs > 0 ? " · \(tabs) 个标签页" : "")
        statusLabel.stringValue = "● " + activity.message
        statusLabel.toolTip = activity.message
        statusLabel.textColor = activity.running ? WorkspaceScenePalette.link : (activity.failed ? WorkspaceScenePalette.warning
            : (activity.message.hasPrefix("已恢复") ? WorkspaceScenePalette.success : WorkspaceScenePalette.secondary))
        captureButton.isEnabled = canCapture
        saveButton.isEnabled = canSave
        restoreButton.isEnabled = canRestore
        background.configure(running: activity.running)
        setAccessibilityLabel("\(desktop.label)，\(activity.message)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        checkbox.frame = NSRect(x: 14, y: 34, width: 18, height: 22)
        titleLabel.frame = NSRect(x: 41, y: 23, width: 118, height: 19)
        subtitleLabel.frame = NSRect(x: 41, y: 46, width: 126, height: 17)
        let right: CGFloat = 155
        let middleX: CGFloat = 182
        let middleWidth = max(bounds.width - middleX - right - 24, 80)
        let chipHeight = chips.requiredHeight(for: middleWidth)
        let summaryY = (bounds.height - chipHeight - 20) / 2
        chips.frame = NSRect(x: middleX, y: summaryY, width: middleWidth, height: chipHeight)
        countLabel.frame = NSRect(x: middleX, y: summaryY + chipHeight + 3, width: middleWidth, height: 16)
        statusLabel.frame = NSRect(x: bounds.width - right - 14, y: 19, width: right, height: 18)
        var x = bounds.width - 14 - 3 * 39
        for button in [captureButton, saveButton, restoreButton] {
            button.frame = NSRect(x: x, y: 45, width: 39, height: 27)
            x += 39
        }
    }

    /// 多窗口桌面按标题实际换行数增高，避免隐藏失败窗口的标题。
    func preferredHeight(for width: CGFloat) -> CGFloat {
        max(90, chips.requiredHeight(for: max(width - 182 - 155 - 24, 80)) + 40)
    }

    /// 标签和空白区域只聚焦明细，复选框及业务按钮保持各自的独立动作。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    @objc private func toggle() { if enabled { onToggle?() } }
    @objc private func capture() { onCapture?() }
    @objc private func save() { onSave?() }
    @objc private func restore() { onRestore?() }
}
