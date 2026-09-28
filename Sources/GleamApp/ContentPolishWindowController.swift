import AppKit

/// 润色控制器只管理草稿与动作，共享毛玻璃视图不持有业务会话。
@MainActor
final class ContentPolishWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let session: ContentPolishSession
    let roleField: NSTextField
    let scenarioField: NSTextField
    let tonePicker: NSPopUpButton
    let content: WritingPanelView
    var sourceView: NSTextView { content.sourceView }
    var resultView: NSTextView { content.resultView }
    var runButton: NSButton { content.runButton }
    var copyButton: NSButton { content.copyButton }
    var statusLabel: NSTextField { content.statusLabel }

    init(session: ContentPolishSession) {
        self.session = session
        let role = NSTextField(string: "")
        let scenario = NSTextField(string: "")
        let tone = NSPopUpButton(frame: .zero, pullsDown: false)
        roleField = role
        scenarioField = scenario
        tonePicker = tone
        let view = WritingPanelView(title: "内容润色", symbol: "square.and.pencil",
                                    sourceTitle: "原文", resultTitle: "润色结果",
                                    fieldRows: [[("角色", role), ("场景", scenario), ("预期语气", tone)]])
        content = view
        let panel = WritingPanel(title: "内容润色", content: view)
        super.init(window: panel)
        panel.delegate = self
        roleField.delegate = self
        scenarioField.delegate = self
        sourceView.delegate = self
        tonePicker.addItems(withTitles: PolishTone.allCases.map(\.title))
        tonePicker.target = self
        tonePicker.action = #selector(toneChanged)
        for (button, action) in [(runButton, #selector(runPolish)), (copyButton, #selector(copyResult)),
                                 (content.cancelButton, #selector(cancelPolish)), (content.closeButton, #selector(closePanel))] {
            button.target = self
            button.action = action
        }
        copyButton.setAccessibilityLabel("复制润色结果")
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 必须先由入口完成选区捕获，再让窗口抢焦点；有效原文只自动提交一次。
    func show(sourceText: String, on screen: NSScreen?, captureError: String? = nil) {
        session.open(sourceText: sourceText, captureError: captureError)
        if captureError == nil, !session.currentRequest.text.isEmpty { session.polish() }
        reveal(on: screen)
    }

    /// 已打开的草稿可直接唤起，不因再次显示而触发重复请求。
    func reveal(on screen: NSScreen?) {
        (window as? WritingPanel)?.reveal(on: screen)
        focusSourceText()
    }

    /// 焦点只在打开时移到原文末尾，模型响应不会打断用户正在选择的结果。
    func focusSourceText() {
        window?.makeFirstResponder(sourceView)
        let range = NSRange(location: sourceView.string.utf16.count, length: 0)
        sourceView.setSelectedRange(range)
        sourceView.scrollRangeToVisible(range)
    }

    func windowWillClose(_ notification: Notification) { session.cancel() }
    func controlTextDidChange(_ notification: Notification) { updateSession() }
    func textDidChange(_ notification: Notification) { updateSession() }

    /// 只更新有差异的文本，保留光标与选择；旧结果继续显示其生成时的上下文。
    private func render() {
        if roleField.stringValue != session.preferences.role { roleField.stringValue = session.preferences.role }
        if scenarioField.stringValue != session.preferences.scenario { scenarioField.stringValue = session.preferences.scenario }
        tonePicker.selectItem(at: PolishTone.allCases.firstIndex(of: session.preferences.tone) ?? 0)
        if sourceView.string != session.sourceText { sourceView.string = session.sourceText }
        let resultText = session.result?.text ?? ""
        if resultView.string != resultText { resultView.string = resultText }
        content.countLabel.stringValue = "\(session.sourceText.count) 字"
        content.contextLabel.stringValue = session.result?.request.contextDescription ?? "润色后保留原文语言与原意"
        content.contextLabel.toolTip = content.contextLabel.stringValue
        roleField.isEnabled = !session.isLoading
        scenarioField.isEnabled = !session.isLoading
        tonePicker.isEnabled = !session.isLoading
        sourceView.isEditable = !session.isLoading
        runButton.isEnabled = !session.isLoading && !session.currentRequest.text.isEmpty
        copyButton.isEnabled = session.result != nil
        content.feedbackLabel.stringValue = session.isDirty ? "参数或原文已修改" : ""
        switch session.phase {
        case .loading:
            content.updateFeedback(loading: true, status: "正在润色…", action: "润色中")
            content.feedbackLabel.stringValue = session.result == nil ? "" : "保留上次结果"
        case .error(let message):
            content.updateFeedback(loading: false, status: "未完成", action: "重试", error: message, color: .systemRed)
        case .idle:
            content.updateFeedback(loading: false, status: session.result?.completion.status("已润色") ?? "等待润色",
                                   action: session.result == nil ? "开始润色" : "重新润色",
                                   color: session.isDirty ? .systemOrange : session.result == nil ? .secondaryLabelColor : .systemGreen)
        }
    }

    /// 所有编辑入口汇总到同一份原文快照，角色与场景修改不自动发请求。
    private func updateSession() {
        let index = tonePicker.indexOfSelectedItem
        guard PolishTone.allCases.indices.contains(index) else { return }
        session.update(sourceText: sourceView.string, preferences: PolishPreferences(
            role: roleField.stringValue, scenario: scenarioField.stringValue, tone: PolishTone.allCases[index]
        ))
    }

    /// 沿用语气切换即润色的行为；相同语气或空原文不触发请求。
    @objc private func toneChanged() {
        guard !session.isLoading else { return }
        let previous = session.preferences.tone
        updateSession()
        guard session.preferences.tone != previous, !session.currentRequest.text.isEmpty else { return }
        session.polish()
    }

    /// 手动重试读取最新控件值，但始终使用原文而非旧结果。
    @objc private func runPolish() { updateSession(); session.polish() }
    @objc private func cancelPolish() { session.cancel() }
    @objc private func closePanel() { close() }

    /// 剪贴板写入成功才关闭，失败时保留窗口和可再次复制的结果。
    @objc private func copyResult() {
        guard let result = session.result else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(result.text, forType: .string) { close() }
    }
}
