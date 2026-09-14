import AppKit

/// 双栏原生弹出面板；保留现有 NSMenuItem 作为命令来源，统一关闭后投递原 selector。
@MainActor
final class PowerPopoverController: NSObject, NSPopoverDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    var onShowPowerChange: ((Bool) -> Void)?
    private let popover = NSPopover()
    let content: PowerPopoverContentController
    private weak var statusButton: NSStatusBarButton?

    var isShown: Bool { popover.isShown }

    init(menu: NSMenu, showPower: Bool) {
        content = PowerPopoverContentController(menu: menu, showPower: showPower)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 490, height: 450)
        popover.delegate = self
        content.onDismiss = { [weak self] in self?.close() }
        content.onCommand = { [weak self] item in
            self?.close()
            // 下一次主线程循环再执行，确保关闭完成且来源应用不会被面板焦点替换。
            DispatchQueue.main.async {
                if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            }
        }
        content.info.onShowPowerChange = { [weak self] showPower in self?.onShowPowerChange?(showPower) }
    }

    /// 跟随被点击的原生按钮定位；再次点击关闭，展开时限制高度并立即启用面板采样。
    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close(); return }
        statusButton = button
        content.refreshCommands()
        let available = button.window?.screen?.visibleFrame.height ?? 900
        let height = min(450, max(340, available - 40))
        content.setViewportHeight(height)
        popover.contentSize = NSSize(width: 490, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        content.focusCommand(at: 0)
    }

    func close() { popover.performClose(nil) }

    func update(snapshot: PowerSnapshot, presentation: PowerPresentation) {
        content.info.update(snapshot: snapshot, presentation: presentation)
    }

    func refreshCommands() { content.refreshCommands() }

    func popoverDidShow(_ notification: Notification) { onVisibilityChange?(true) }

    func popoverDidClose(_ notification: Notification) {
        statusButton?.highlight(false)
        onVisibilityChange?(false)
    }
}

/// 电源左栏与可滚动命令右栏各自布局，适应可用屏幕高度而不裁掉底部命令。
@MainActor
final class PowerPopoverContentController: NSViewController {
    var onCommand: ((NSMenuItem) -> Void)?
    var onDismiss: (() -> Void)?
    let info: PowerInfoView
    private let commands: NSMenu
    private var commandButtons: [PowerCommandButton] = []
    private var viewportHeight: NSLayoutConstraint?

    init(menu: NSMenu, showPower: Bool) {
        self.commands = menu
        info = PowerInfoView(showPower: showPower)
        super.init(nibName: nil, bundle: nil)
        _ = view
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 490, height: 450))
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        view = background
        // 滚动容器没有固有高度，显式定义视口，避免自动布局把弹出窗口压缩到分隔线高度。
        viewportHeight = view.heightAnchor.constraint(equalToConstant: 450)
        viewportHeight?.isActive = true
        view.widthAnchor.constraint(equalToConstant: 490).isActive = true
        let line = NSBox()
        line.boxType = .separator
        let scroll = Self.topAlignedScrollView()
        let infoScroll = Self.topAlignedScrollView()
        info.translatesAutoresizingMaskIntoConstraints = false
        infoScroll.documentView = info
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: infoScroll.contentView.leadingAnchor),
            info.topAnchor.constraint(equalTo: infoScroll.contentView.topAnchor),
            info.widthAnchor.constraint(equalTo: infoScroll.contentView.widthAnchor),
            info.heightAnchor.constraint(equalToConstant: 450)
        ])
        let columns = NSStackView(views: [infoScroll, line, scroll])
        columns.spacing = 0
        columns.alignment = .top
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columns.topAnchor.constraint(equalTo: view.topAnchor),
            columns.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            infoScroll.widthAnchor.constraint(equalToConstant: 220),
            infoScroll.heightAnchor.constraint(equalTo: columns.heightAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalTo: columns.heightAnchor),
            scroll.widthAnchor.constraint(equalTo: columns.widthAnchor, constant: -221),
            scroll.heightAnchor.constraint(equalTo: columns.heightAnchor)
        ])
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.edgeInsets = NSEdgeInsets(top: 9, left: 7, bottom: 9, right: 7)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        for item in commands.items {
            if item.isSeparatorItem {
                let separator = NSBox()
                separator.boxType = .separator
                let wrapper = NSView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                wrapper.addSubview(separator)
                NSLayoutConstraint.activate([
                    wrapper.heightAnchor.constraint(equalToConstant: 12),
                    separator.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 7),
                    separator.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -7),
                    separator.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
                ])
                rows.addArrangedSubview(wrapper)
                wrapper.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -14).isActive = true
            } else {
                let button = PowerCommandButton(item: item)
                button.target = self
                button.action = #selector(invokeCommand(_:))
                button.onDismiss = { [weak self] in self?.onDismiss?() }
                button.onMove = { [weak self, weak button] delta in
                    guard let self, let button, let index = self.commandButtons.firstIndex(of: button) else { return }
                    self.focusCommand(at: index + delta)
                }
                rows.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -14).isActive = true
                button.heightAnchor.constraint(equalToConstant: 29).isActive = true
                commandButtons.append(button)
            }
        }
    }

    func setViewportHeight(_ height: CGFloat) { viewportHeight?.constant = height }

    /// 翻转裁剪坐标让短内容贴顶；两栏独立滚动，小屏仍能访问功率开关和退出命令。
    private static func topAlignedScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = PowerTopClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    /// 休眠或模型改变时复用原菜单对象更新标题，不重新构造面板或丢失键盘焦点。
    func refreshCommands() { commandButtons.forEach { $0.refreshTitle() } }

    /// 上下方向键循环命令，原生 Tab 仍可进入左栏的功率复选框。
    func focusCommand(at index: Int) {
        guard !commandButtons.isEmpty else { return }
        let normalized = (index + commandButtons.count) % commandButtons.count
        let button = commandButtons[normalized]
        view.window?.makeFirstResponder(button)
        button.scrollToVisible(button.bounds)
    }

    @objc private func invokeCommand(_ sender: PowerCommandButton) { onCommand?(sender.item) }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

/// AppKit 默认文档坐标从底部开始；电源面板统一从顶部展示初始内容。
@MainActor
private final class PowerTopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// 原生按钮保留无障碍与键盘事件，只增加菜单行的悬停外观。
@MainActor
private final class PowerCommandButton: NSButton {
    let item: NSMenuItem
    var onMove: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(item: NSMenuItem) {
        self.item = item
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 13)
        contentTintColor = .labelColor
        keyEquivalent = item.keyEquivalent
        keyEquivalentModifierMask = item.keyEquivalentModifierMask
        wantsLayer = true
        layer?.cornerRadius = 5
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        title = "  " + item.title
        isEnabled = item.isEnabled
        setAccessibilityLabel(item.title)
        toolTip = item.title
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateHighlight() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateHighlight() }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); updateHighlight(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); hovering = false; layer?.backgroundColor = nil; return result }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateHighlight() }

    private func updateHighlight() {
        layer?.backgroundColor = hovering || window?.firstResponder === self
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1)
        case 126: onMove?(-1)
        case 36, 76: performClick(nil)
        case 53: onDismiss?()
        default: super.keyDown(with: event)
        }
    }
}
