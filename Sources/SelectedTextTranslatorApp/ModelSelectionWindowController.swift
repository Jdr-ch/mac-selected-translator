import AppKit

/// Read-only model panel: the tabs select a provider, while all configuration stays in its CLI.
@MainActor
final class ModelSelectionWindowController: NSWindowController, NSWindowDelegate {
    let session: ModelSelectionSession
    let modelLabel = NSTextField(labelWithString: "正在读取...")
    let sourceLabel = NSTextField(labelWithString: "")
    let defaultLabel = NSTextField(labelWithString: "全局默认")
    private(set) var tabs: [NSButton] = []
    private var indicators: [NSView] = []
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    init(session: ModelSelectionSession) {
        self.session = session
        let panel = ModelSelectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 552, height: 246),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.title = "模型切换"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
        layoutControls()
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Center on the invoking display; native key-window notifications also refresh external edits.
    func show(on screen: NSScreen?) {
        if let screen, let window {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        } else {
            window?.center()
        }
        if window?.isKeyWindow == true { session.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { session.refresh() }
    func windowWillClose(_ notification: Notification) { session.cancel() }

    private func layoutControls() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        window?.backgroundColor = .windowBackgroundColor
        let title = NSTextField(labelWithString: "模型切换")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.isBordered = false
        closeButton.toolTip = "关闭"
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        let tabRow = NSStackView()
        tabRow.distribution = .fillEqually
        tabRow.spacing = 0
        let tabRule = NSBox()
        tabRule.boxType = .separator
        let footerRule = NSBox()
        footerRule.boxType = .separator
        let caption = NSTextField(labelWithString: "当前模型")
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        modelLabel.font = .systemFont(ofSize: 24, weight: .medium)
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelLabel.setAccessibilityLabel("当前模型")
        defaultLabel.font = .systemFont(ofSize: 12)
        defaultLabel.textColor = .systemGreen
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!)
        check.contentTintColor = .systemGreen
        let selected = NSStackView(views: [check, defaultLabel])
        selected.spacing = 6
        let sourceCaption = NSTextField(labelWithString: "配置来源")
        sourceCaption.font = .systemFont(ofSize: 11)
        sourceCaption.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setAccessibilityLabel("配置来源")
        let footer = NSStackView(views: [sourceCaption, sourceLabel])
        footer.spacing = 12
        for view in [title, closeButton, tabRow, tabRule, caption, modelLabel, selected, footerRule, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for (index, provider) in ModelProvider.allCases.enumerated() {
            let button = NSButton(title: provider.title, target: self, action: #selector(selectTab(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.toolTip = "切换到 \(provider.title)"
            button.setAccessibilityLabel(provider.title)
            tabs.append(button)
            tabRow.addArrangedSubview(button)
            let indicator = NSView()
            indicator.wantsLayer = true
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicators.append(indicator)
            content.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                indicator.widthAnchor.constraint(equalTo: button.widthAnchor, constant: -60),
                indicator.topAnchor.constraint(equalTo: tabRule.topAnchor),
                indicator.heightAnchor.constraint(equalToConstant: 2)
            ])
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            tabRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            tabRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            tabRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 56),
            tabRow.heightAnchor.constraint(equalToConstant: 36),
            tabRule.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor),
            tabRule.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
            tabRule.topAnchor.constraint(equalTo: content.topAnchor, constant: 97),
            caption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 119),
            modelLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 144),
            modelLabel.trailingAnchor.constraint(lessThanOrEqualTo: selected.leadingAnchor, constant: -16),
            selected.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
            selected.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            check.heightAnchor.constraint(equalToConstant: 12),
            footerRule.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
            footerRule.topAnchor.constraint(equalTo: content.topAnchor, constant: 199),
            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: tabRow.trailingAnchor),
            footer.topAnchor.constraint(equalTo: content.topAnchor, constant: 214)
        ])
    }

    /// Render loading/error text in the same stable layout; green denotes selection, not connectivity.
    private func render() {
        let provider = session.selection.provider
        for (index, value) in ModelProvider.allCases.enumerated() {
            let selected = value == provider
            tabs[index].contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            tabs[index].setAccessibilityValue(selected ? "已选中" : "未选中")
            indicators[index].layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            indicators[index].isHidden = !selected
        }
        sourceLabel.stringValue = provider.source
        sourceLabel.toolTip = provider.source
        modelLabel.textColor = .labelColor
        modelLabel.font = .systemFont(ofSize: 24, weight: .medium)
        switch session.phase {
        case .loading:
            modelLabel.stringValue = "正在读取..."
            modelLabel.textColor = .secondaryLabelColor
        case .loaded(let information):
            modelLabel.stringValue = information.model
            sourceLabel.stringValue = information.source
            sourceLabel.toolTip = information.source
        case .failed(let message):
            modelLabel.stringValue = "配置读取失败"
            modelLabel.textColor = .systemRed
            modelLabel.font = .systemFont(ofSize: 18, weight: .medium)
            modelLabel.toolTip = message
            return
        }
        modelLabel.toolTip = modelLabel.stringValue
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard ModelProvider.allCases.indices.contains(sender.tag) else { return }
        session.select(ModelProvider.allCases[sender.tag])
    }

    @objc private func closePanel() { close() }
}

/// A borderless utility still needs native keyboard eligibility and Escape-to-close behavior.
private final class ModelSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}
