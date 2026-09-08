import AppKit

/// A retained editing window, unlike the transient translation panel, stays open on outside clicks.
@MainActor
final class ContentPolishWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let session: ContentPolishSession
    let roleField = NSTextField(string: "")
    let scenarioField = NSTextField(string: "")
    let tonePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let sourceView = NSTextView()
    let resultView = NSTextView()
    let runButton = NSButton(title: "开始润色", target: nil, action: nil)
    let copyButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let roleError = NSTextField(labelWithString: "")
    private let scenarioError = NSTextField(labelWithString: "")
    private var errorHeight: NSLayoutConstraint!

    init(session: ContentPolishSession) {
        self.session = session
        let panel = ContentPolishPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "内容润色"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // 使用普通窗口层级，切换到其他应用后允许其窗口覆盖润色窗口。
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 600, height: 540)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
        panel.initialFirstResponder = sourceView
        configureControls()
        layoutControls()
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called after selection capture, so making this panel key cannot steal the source selection.
    func show(sourceText: String, on screen: NSScreen?, captureError: String? = nil) {
        session.open(sourceText: sourceText, captureError: captureError)
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.polish()
        }
        // 自动请求先切换控件状态，再定位原文焦点，避免 loading 更新干扰首次焦点。
        reveal(on: screen)
    }

    /// Reuses one window and centers it within the screen where the menu command was invoked.
    func reveal(on screen: NSScreen?) {
        if let screen {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(680, visible.width), height: min(540, visible.height))
            window?.setFrame(NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ), display: true)
        } else {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusSourceText()
    }

    /// 仅在打开或再次唤起弹窗时聚焦原文末尾；结果刷新时不抢走用户正在操作的焦点。
    func focusSourceText() {
        window?.makeFirstResponder(sourceView)
        let insertionRange = NSRange(location: sourceView.string.utf16.count, length: 0)
        sourceView.setSelectedRange(insertionRange)
        sourceView.scrollRangeToVisible(insertionRange)
    }

    func windowWillClose(_ notification: Notification) {
        session.cancel()
    }

    /// All editable controls share one session snapshot, including native paste and menu edits.
    func controlTextDidChange(_ notification: Notification) { updateSession() }
    func textDidChange(_ notification: Notification) { updateSession() }

    private func configureControls() {
        roleField.delegate = self
        scenarioField.delegate = self
        sourceView.delegate = self
        roleField.setAccessibilityLabel("角色")
        scenarioField.setAccessibilityLabel("场景")
        tonePicker.setAccessibilityLabel("预期")
        sourceView.setAccessibilityLabel("原文")
        resultView.setAccessibilityLabel("润色结果")
        tonePicker.addItems(withTitles: PolishTone.allCases.map(\.title))
        tonePicker.target = self
        tonePicker.action = #selector(toneChanged)
        configureButton(runButton, symbol: "arrow.clockwise", action: #selector(runPolish), label: "重新润色")
        runButton.bezelColor = .controlAccentColor
        runButton.contentTintColor = .white
        configureButton(copyButton, symbol: "doc.on.doc", action: #selector(copyResult), label: "复制润色结果")
        configureButton(closeButton, symbol: "xmark", action: #selector(closePanel), label: "关闭")
        closeButton.isBordered = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelPolish)
        cancelButton.bezelStyle = .rounded
        for label in [countLabel, contextLabel, feedbackLabel, roleError, scenarioError, errorLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        roleError.textColor = .systemRed
        scenarioError.textColor = .systemRed
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12)
    }

    /// Native SF Symbols keep icon actions consistent with the rest of the AppKit application.
    private func configureButton(_ button: NSButton, symbol: String, action: Selector, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .rounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    /// Constrains the title and footer independently of the two scrolling text regions.
    private func layoutControls() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        window?.backgroundColor = .windowBackgroundColor

        let titleIcon = NSImageView(image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)!)
        titleIcon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "内容润色")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        let headerRule = NSBox()
        headerRule.boxType = .separator
        let sourceTitle = NSTextField(labelWithString: "原文")
        let resultTitle = NSTextField(labelWithString: "润色结果")
        sourceTitle.font = .systemFont(ofSize: 13, weight: .medium)
        resultTitle.font = sourceTitle.font
        let sourceScroll = textScrollView(sourceView, editable: true)
        let resultScroll = textScrollView(resultView, editable: false)
        let resultRule = NSBox()
        resultRule.boxType = .separator
        let footerRule = NSBox()
        footerRule.boxType = .separator
        let fields = NSStackView(views: [
            fieldColumn("角色", control: roleField, error: roleError),
            fieldColumn("场景", control: scenarioField, error: scenarioError),
            fieldColumn("预期", control: tonePicker)
        ])
        fields.orientation = .horizontal
        fields.distribution = .fill
        fields.alignment = .top
        fields.spacing = 16
        let columns = fields.arrangedSubviews

        for view in [titleIcon, title, closeButton, headerRule, fields, sourceTitle, countLabel,
                     sourceScroll, resultRule, resultTitle, statusLabel, contextLabel, errorLabel,
                     resultScroll, footerRule, feedbackLabel, cancelButton, runButton, copyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            titleIcon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            titleIcon.widthAnchor.constraint(equalToConstant: 16), titleIcon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30), closeButton.heightAnchor.constraint(equalToConstant: 30),
            headerRule.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            headerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor), headerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fields.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 16),
            fields.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), fields.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            columns[0].widthAnchor.constraint(equalTo: columns[1].widthAnchor, multiplier: 1.3),
            columns[1].widthAnchor.constraint(equalTo: columns[2].widthAnchor),
            sourceTitle.topAnchor.constraint(equalTo: fields.bottomAnchor, constant: 14),
            sourceTitle.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: sourceTitle.centerYAnchor), countLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: sourceTitle.bottomAnchor, constant: 7),
            sourceScroll.leadingAnchor.constraint(equalTo: fields.leadingAnchor), sourceScroll.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            sourceScroll.heightAnchor.constraint(equalToConstant: 94),
            resultRule.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 18),
            resultRule.leadingAnchor.constraint(equalTo: fields.leadingAnchor), resultRule.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            resultTitle.topAnchor.constraint(equalTo: resultRule.bottomAnchor, constant: 14), resultTitle.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: resultTitle.centerYAnchor), statusLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: resultTitle.bottomAnchor, constant: 8),
            contextLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor), contextLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            contextLabel.heightAnchor.constraint(equalToConstant: 18),
            errorLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: fields.trailingAnchor), errorHeight,
            resultScroll.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 4),
            resultScroll.leadingAnchor.constraint(equalTo: fields.leadingAnchor), resultScroll.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
            resultScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -12),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            footerRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -58),
            footerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor), footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            feedbackLabel.leadingAnchor.constraint(equalTo: fields.leadingAnchor), feedbackLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            feedbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: fields.trailingAnchor), copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13),
            copyButton.widthAnchor.constraint(equalToConstant: 34), copyButton.heightAnchor.constraint(equalToConstant: 32),
            runButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8), runButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 106), runButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8), cancelButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 60), cancelButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    /// 参数列保留标签和就地校验，控件采用原生紧凑高度，避免单行文字下方出现多余留白。
    private func fieldColumn(_ title: String, control: NSView, error: NSTextField? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let column = NSStackView(views: [label, control])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        // 固定拉高 NSTextField 不会同步居中文字；保持原生固有高度，并禁止垂直拉伸。
        control.setContentHuggingPriority(.required, for: .vertical)
        if let error {
            column.addArrangedSubview(error)
            error.isHidden = true
        }
        return column
    }

    /// Text containers track viewport width; long selections/results scroll without resizing the window.
    private func textScrollView(_ textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = editable ? .bezelBorder : .noBorder
        scroll.drawsBackground = editable
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: editable ? 13 : 14)
        textView.textColor = .labelColor
        textView.drawsBackground = editable
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: editable ? 8 : 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    /// Derives all visible request states from the session while leaving the editor cursor intact.
    private func render() {
        if roleField.stringValue != session.preferences.role { roleField.stringValue = session.preferences.role }
        if scenarioField.stringValue != session.preferences.scenario { scenarioField.stringValue = session.preferences.scenario }
        tonePicker.selectItem(at: PolishTone.allCases.firstIndex(of: session.preferences.tone) ?? 0)
        if sourceView.string != session.sourceText { sourceView.string = session.sourceText }
        let resultText = session.result?.text ?? ""
        if resultView.string != resultText { resultView.string = resultText }
        countLabel.stringValue = "\(session.sourceText.count) 字"
        contextLabel.stringValue = session.result?.request.contextDescription ?? ""
        contextLabel.toolTip = contextLabel.stringValue
        roleField.isEnabled = !session.isLoading
        scenarioField.isEnabled = !session.isLoading
        tonePicker.isEnabled = !session.isLoading
        sourceView.isEditable = !session.isLoading
        runButton.isEnabled = !session.isLoading && !session.currentRequest.text.isEmpty
        copyButton.isEnabled = session.result != nil
        cancelButton.isHidden = !session.isLoading
        roleError.isHidden = true
        scenarioError.isHidden = true
        errorLabel.stringValue = ""
        feedbackLabel.stringValue = session.isDirty ? "参数或原文已修改" : ""
        statusLabel.textColor = .secondaryLabelColor
        switch session.phase {
        case .loading:
            statusLabel.stringValue = "正在润色..."
            runButton.title = "润色中"
            feedbackLabel.stringValue = session.result == nil ? "" : "保留上次结果"
        case .error(let message):
            statusLabel.stringValue = "未完成"
            statusLabel.textColor = .systemRed
            runButton.title = "重试"
            errorLabel.stringValue = message
            if session.currentRequest.role.isEmpty { roleError.stringValue = "请填写角色"; roleError.isHidden = false }
            if session.currentRequest.scenario.isEmpty { scenarioError.stringValue = "请填写场景"; scenarioError.isHidden = false }
        case .idle:
            statusLabel.stringValue = session.isDirty ? "待重新润色" : session.result == nil ? "等待润色" : "已完成"
            statusLabel.textColor = session.isDirty ? .systemOrange : session.result == nil ? .secondaryLabelColor : .systemGreen
            runButton.title = session.result == nil ? "开始润色" : "重新润色"
        }
        errorHeight.constant = errorLabel.stringValue.isEmpty ? 0 : 42
        errorLabel.toolTip = errorLabel.stringValue
    }

    /// 将当前编辑内容写入会话草稿；角色和场景的编辑本身不触发模型请求。
    private func updateSession() {
        let index = tonePicker.indexOfSelectedItem
        guard PolishTone.allCases.indices.contains(index) else { return }
        session.update(sourceText: sourceView.string, preferences: PolishPreferences(
            role: roleField.stringValue, scenario: scenarioField.stringValue, tone: PolishTone.allCases[index]
        ))
    }

    /// 预期语气变化后基于当前原文立即润色；复用会话的校验、请求锁与旧结果保留逻辑。
    @objc private func toneChanged() {
        guard !session.isLoading else { return }
        let previousTone = session.preferences.tone
        updateSession()
        // 未改变语气或尚无原文时只保留选择，不发送重复请求或空请求。
        guard session.preferences.tone != previousTone, !session.currentRequest.text.isEmpty else { return }
        session.polish()
    }

    /// 手动重新润色先读取全部编辑框，确保提交最新的角色、场景和原文。
    @objc private func runPolish() { updateSession(); session.polish() }
    @objc private func cancelPolish() { session.cancel() }
    @objc private func closePanel() { close() }

    /// 复制完整润色结果；只有剪贴板写入成功后才关闭窗口，避免复制失败时丢失当前结果。
    @objc private func copyResult() {
        guard let result = session.result else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(result.text, forType: .string) {
            feedbackLabel.stringValue = "已复制"
            close()
        }
    }
}

/// Borderless panels need explicit key eligibility for native input, paste, and text selection.
private final class ContentPolishPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    /// This menu-bar app has no Edit menu, so route standard editing shortcuts to the field editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            let actions = ["c": "copy:", "x": "cut:", "v": "paste:", "a": "selectAll:"]
            if let action = actions[key], let responder = firstResponder {
                return NSApp.sendAction(Selector(action), to: responder, from: self)
            }
            if key == "z", let manager = firstResponder?.undoManager {
                if event.modifierFlags.contains(.shift) { manager.redo() } else { manager.undo() }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
