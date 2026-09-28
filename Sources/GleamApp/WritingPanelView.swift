import AppKit

/// 润色和回复共用外观与编辑控件；请求、参数持久化及打开策略留在各自控制器。
@MainActor
final class WritingPanelView: NSVisualEffectView {
    let sourceView = NSTextView()
    let resultView = NSTextView()
    let runButton = NSButton(title: "", target: nil, action: nil)
    let copyButton = NSButton(title: "复制", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let contextLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let feedbackLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var errorHeight: NSLayoutConstraint!
    private var textRegions: [NSScrollView] = []
    /// 毛玻璃背景上的辅助文字集中解析颜色，避免系统 vibrancy 把深色辅助文字绘成黑色。
    private var fieldLabels: [NSTextField] = []
    /// 保留语义颜色源，主题切换时重新解析，避免等待/加载文字沿用旧主题的灰色。
    private var statusColor = NSColor.secondaryLabelColor

    init(title: String, symbol: String, sourceTitle: String, resultTitle: String,
         fieldRows: [[(String, NSView)]]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        material = .popover
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        configureButton(runButton, symbol: "sparkles", label: "生成")
        configureButton(copyButton, symbol: "doc.on.doc", label: "复制结果")
        configureButton(closeButton, symbol: "xmark", label: "关闭")
        closeButton.isBordered = false
        cancelButton.bezelStyle = .rounded
        runButton.bezelColor = .controlAccentColor
        runButton.contentTintColor = .white
        runButton.keyEquivalent = "\r"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        for label in [countLabel, statusLabel, contextLabel, feedbackLabel, errorLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [statusLabel, contextLabel, feedbackLabel] { label.lineBreakMode = .byTruncatingTail }
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        sourceView.setAccessibilityLabel(sourceTitle)
        resultView.setAccessibilityLabel(resultTitle)
        layoutControls(title: title, symbol: symbol, sourceTitle: sourceTitle,
                       resultTitle: resultTitle, fieldRows: fieldRows)
        updateAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// 调用方提供业务动作；共享层仅维护原生符号、可访问名称与按钮样式。
    private func configureButton(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = button === closeButton ? .imageOnly : .imageLeading
        button.bezelStyle = .rounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// 参数按原生固有高度排布；剩余高度全部分给结果，长文本在独立区域滚动。
    private func layoutControls(title: String, symbol: String, sourceTitle: String,
                                resultTitle: String, fieldRows: [[(String, NSView)]]) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let sourceLabel = NSTextField(labelWithString: sourceTitle)
        let resultLabel = NSTextField(labelWithString: resultTitle)
        for label in [sourceLabel, resultLabel] { label.font = .systemFont(ofSize: 13, weight: .medium) }
        let headerRule = NSBox()
        let footerRule = NSBox()
        headerRule.boxType = .separator
        footerRule.boxType = .separator
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 12
        for row in fieldRows {
            let columns = NSStackView(views: row.map { fieldColumn($0.0, control: $0.1) })
            columns.distribution = .fillEqually
            columns.alignment = .top
            columns.spacing = 16
            fields.addArrangedSubview(columns)
            columns.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        }
        let sourceScroll = textScrollView(sourceView, editable: true)
        let resultScroll = textScrollView(resultView, editable: false)
        textRegions = [sourceScroll, resultScroll]
        for view in [icon, heading, closeButton, headerRule, fields, sourceLabel, countLabel,
                     sourceScroll, resultLabel, progress, statusLabel, contextLabel, errorLabel,
                     resultScroll, footerRule, feedbackLabel, cancelButton, runButton, copyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: topAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            heading.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30), closeButton.heightAnchor.constraint(equalToConstant: 30),
            headerRule.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor), headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            fields.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 16),
            fields.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            fields.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            sourceLabel.topAnchor.constraint(equalTo: fields.bottomAnchor, constant: 16),
            sourceLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: sourceLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 6),
            sourceScroll.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            sourceScroll.heightAnchor.constraint(equalToConstant: 104),
            resultLabel.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 16),
            resultLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: resultLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            progress.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            progress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 14), progress.heightAnchor.constraint(equalToConstant: 14),
            progress.leadingAnchor.constraint(greaterThanOrEqualTo: resultLabel.trailingAnchor, constant: 12),
            contextLabel.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 6),
            contextLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            contextLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            contextLabel.heightAnchor.constraint(equalToConstant: 16),
            errorLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor), errorHeight,
            resultScroll.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 6),
            resultScroll.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            resultScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -14),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            footerRule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -58),
            footerRule.leadingAnchor.constraint(equalTo: leadingAnchor), footerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            copyButton.widthAnchor.constraint(equalToConstant: 80), copyButton.heightAnchor.constraint(equalToConstant: 32),
            runButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            runButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 112), runButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 60), cancelButton.heightAnchor.constraint(equalToConstant: 32),
            feedbackLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            feedbackLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            feedbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8)
        ])
    }

    /// 单行控件不额外拉高，避免文字下方出现无法利用的空白。
    private func fieldColumn(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        fieldLabels.append(label)
        control.setAccessibilityLabel(title)
        if let field = control as? NSTextField { field.bezelStyle = .roundedBezel }
        let column = NSStackView(views: [label, control])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        control.setContentHuggingPriority(.required, for: .vertical)
        return column
    }

    /// 保留原生文本选择、撤销和自动换行，结果只读但可复制。
    private func textScrollView(_ text: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 0.5
        scroll.layer?.masksToBounds = true
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = editable
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize: 14)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }

    /// 统一展示加载、错误和操作名称，不推断润色或回复的业务阶段。
    func updateFeedback(loading: Bool, status: String, action: String, error: String = "",
                        color: NSColor = .secondaryLabelColor) {
        statusColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            statusLabel.textColor = statusColor.usingColorSpace(.deviceRGB)
        }
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        runButton.title = action
        runButton.setAccessibilityLabel(action)
        runButton.toolTip = action
        cancelButton.isHidden = !loading
        errorLabel.stringValue = error
        errorLabel.toolTip = error
        errorHeight.constant = error.isEmpty ? 0 : 42
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

    /// 图层颜色跟随系统主题；减少透明度时提供实色底，仍保留相同布局和对比度。
    @objc private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            layer?.backgroundColor = (reduce ? NSColor.windowBackgroundColor : .clear).cgColor
            let secondary = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)
            statusLabel.textColor = statusColor.usingColorSpace(.deviceRGB)
            for label in fieldLabels + [countLabel, contextLabel, feedbackLabel] { label.textColor = secondary }
            closeButton.contentTintColor = secondary
            for region in textRegions {
                region.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(reduce ? 1 : 0.55)
                region.layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }
}

/// 两个编辑面板均为普通层级窗口；原生编辑快捷键不依赖菜单栏 App 的 Edit 菜单。
@MainActor
final class WritingPanel: NSPanel {
    init(title: String, content: WritingPanelView) {
        super.init(contentRect: content.frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 600, height: 560)
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        contentView = content
        initialFirstResponder = content.sourceView
    }

    /// 再次唤起保留用户调整的尺寸，定位到入口所在屏幕的可见区域。
    func reveal(on screen: NSScreen?) {
        if let screen {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
            setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                            width: size.width, height: size.height), display: true)
        } else { center() }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextEditingShortcuts.perform(with: event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
