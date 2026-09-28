import AppKit

/// 智能回复只接受用户输入的对方原文，打开路径不依赖选区读取器。
@MainActor
final class SmartReplyWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let session: SmartReplySession
    let myRoleField: NSTextField
    let otherRoleField: NSTextField
    let scenarioField: NSTextField
    let tonePicker: NSPopUpButton
    let content: WritingPanelView
    var sourceView: NSTextView { content.sourceView }
    var resultView: NSTextView { content.resultView }

    init(session: SmartReplySession) {
        self.session = session
        let myRole = NSTextField(string: "")
        let otherRole = NSTextField(string: "")
        let scenario = NSTextField(string: "")
        let tone = NSPopUpButton(frame: .zero, pullsDown: false)
        myRoleField = myRole
        otherRoleField = otherRole
        scenarioField = scenario
        tonePicker = tone
        let view = WritingPanelView(title: "智能回复", symbol: "bubble.left.and.bubble.right",
                                    sourceTitle: "对方原文", resultTitle: "建议回复",
                                    fieldRows: [[("我的角色", myRole), ("对方角色", otherRole)],
                                                [("场景", scenario), ("预期语气", tone)]])
        content = view
        let panel = WritingPanel(title: "智能回复", content: view)
        super.init(window: panel)
        panel.delegate = self
        for field in [myRoleField, otherRoleField, scenarioField] { field.delegate = self }
        sourceView.delegate = self
        tonePicker.addItems(withTitles: PolishTone.allCases.map(\.title))
        tonePicker.target = self
        tonePicker.action = #selector(toneChanged)
        for (button, action) in [(content.runButton, #selector(generateReply)), (content.copyButton, #selector(copyResult)),
                                 (content.cancelButton, #selector(cancelReply)), (content.closeButton, #selector(closePanel))] {
            button.target = self
            button.action = action
        }
        content.copyButton.setAccessibilityLabel("复制建议回复")
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 可见窗口只唤起草稿；关闭后重新打开清空原文和结果，始终不自动生成。
    func show(on screen: NSScreen?) {
        if window?.isVisible != true { session.open() }
        (window as? WritingPanel)?.reveal(on: screen)
        window?.makeFirstResponder(sourceView)
        sourceView.setSelectedRange(NSRange(location: sourceView.string.utf16.count, length: 0))
    }

    func windowWillClose(_ notification: Notification) { session.cancel() }
    func controlTextDidChange(_ notification: Notification) { updateSession() }
    func textDidChange(_ notification: Notification) { updateSession() }

    /// 响应只更新结果区域；草稿与上次成功请求不一致时保留可见提醒。
    private func render() {
        for (field, value) in [(myRoleField, session.preferences.myRole), (otherRoleField, session.preferences.otherRole),
                               (scenarioField, session.preferences.scenario)] {
            if field.stringValue != value { field.stringValue = value }
            field.isEnabled = !session.isLoading
        }
        tonePicker.selectItem(at: PolishTone.allCases.firstIndex(of: session.preferences.tone) ?? 0)
        tonePicker.isEnabled = !session.isLoading
        if sourceView.string != session.sourceText { sourceView.string = session.sourceText }
        sourceView.isEditable = !session.isLoading
        let text = session.result?.text ?? ""
        if resultView.string != text { resultView.string = text }
        content.countLabel.stringValue = "\(session.sourceText.count) 字"
        content.contextLabel.stringValue = session.result?.request.contextDescription ?? "以我的身份回应对方"
        content.contextLabel.toolTip = content.contextLabel.stringValue
        content.runButton.isEnabled = !session.isLoading && !session.currentRequest.text.isEmpty
        content.copyButton.isEnabled = session.result != nil
        content.feedbackLabel.stringValue = session.isDirty ? "参数或原文已修改" : ""
        switch session.phase {
        case .loading:
            content.updateFeedback(loading: true, status: "正在生成回复…", action: "生成中")
            content.feedbackLabel.stringValue = session.result == nil ? "" : "保留上次结果"
        case .error(let message):
            content.updateFeedback(loading: false, status: "未完成", action: "重试", error: message, color: .systemRed)
        case .idle:
            content.updateFeedback(loading: false, status: session.result?.completion.status("已回复") ?? "等待生成",
                                   action: session.result == nil ? "生成回复" : "重新生成",
                                   color: session.isDirty ? .systemOrange : session.result == nil ? .secondaryLabelColor : .systemGreen)
        }
    }

    /// 原文、角色和场景编辑仅更新草稿，提交入口读取这份统一快照。
    private func updateSession() {
        let index = tonePicker.indexOfSelectedItem
        guard PolishTone.allCases.indices.contains(index) else { return }
        session.update(sourceText: sourceView.string, preferences: ReplyPreferences(
            myRole: myRoleField.stringValue, otherRole: otherRoleField.stringValue,
            scenario: scenarioField.stringValue, tone: PolishTone.allCases[index]
        ))
    }

    /// 参数完整时更换语气立即生成，空白或缺角色的草稿不会被自动提交。
    @objc private func toneChanged() {
        guard !session.isLoading else { return }
        let previous = session.preferences.tone
        updateSession()
        guard previous != session.preferences.tone, session.currentRequest.validationMessage == nil else { return }
        session.generate()
    }

    /// 手动生成和重试均提交当前原文，不依赖选中的结果文本。
    @objc private func generateReply() { updateSession(); session.generate() }
    @objc private func cancelReply() { session.cancel() }
    @objc private func closePanel() { close() }

    /// 成功复制完整回复后关闭；失败保留当前会话供再次尝试。
    @objc private func copyResult() {
        guard let result = session.result else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(result.text, forType: .string) { close() }
    }
}
