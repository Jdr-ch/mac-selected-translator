import AppKit
import Testing
@testable import GleamApp

/// 回复会话、原生布局和动作测试；仅模型替身，偏好使用每例独立的存储域。
@Suite(.serialized)
@MainActor
struct SmartReplyTests {
    private static func output(_ text: String) -> ModelTextResult {
        ModelTextResult(text: text, completion: ModelCompletion(provider: .codex, reasoning: .medium, aiMS: 4200))
    }

    @Test func snapshotsKeepRoleDirectionAndOnlySuccessfulPreferencesPersist() async throws {
        let suite = "SmartReplyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [ReplyRequest] = []
        var fail = false
        let session = SmartReplySession(defaults: defaults) { request in
            requests.append(request)
            if fail { throw TranslatorAppError.backendError("回复请求失败") }
            return Self.output("我的回复")
        }
        session.open()
        #expect(requests.isEmpty && session.sourceText.isEmpty)
        #expect(session.preferences == ReplyPreferences())
        session.update(sourceText: " 原始问题 ", preferences: .init(myRole: "开发", otherRole: "经理"))
        await session.generate()?.value
        session.update(sourceText: session.sourceText, preferences: .init(myRole: "经理", otherRole: "开发", tone: .polite))
        #expect(session.isDirty)
        #expect(session.result?.request.myRole == "开发")
        await session.generate()?.value
        #expect(requests.map(\.text) == ["原始问题", "原始问题"])
        #expect(requests.last?.myRole == "经理" && requests.last?.otherRole == "开发")
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(requests[1])) as? [String: String])
        #expect(body["my_role"] == "经理" && body["other_role"] == "开发")
        let saved = session.preferences
        session.update(sourceText: "新问题", preferences: .init(myRole: "客服", otherRole: "客户"))
        fail = true
        await session.generate()?.value
        #expect(session.result?.text == "我的回复")
        #expect(session.phase == .error("回复请求失败"))
        #expect(ReplyPreferences.load(from: defaults) == saved)
        #expect(PolishPreferences.load(from: defaults) == PolishPreferences())
        session.open()
        #expect(session.sourceText.isEmpty && session.result == nil)
        #expect(session.preferences == saved)
        #expect(defaults.data(forKey: ReplyPreferences.storageKey) != nil)
        #expect(defaults.object(forKey: "smartReply.sourceText") == nil)
    }

    @Test func cancellingRejectsLateResponseAndValidationNeverCallsModel() async throws {
        let suite = "SmartReplyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<ModelTextResult, Error>?
        var calls = 0
        let session = SmartReplySession(defaults: defaults) { _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return Self.output("最新回复")
        }
        for preferences in [ReplyPreferences(myRole: ""), .init(otherRole: " "), .init(scenario: ""),
                            .init(myRole: String(repeating: "𠮷", count: 101))] {
            session.update(sourceText: "问题", preferences: preferences)
            #expect(session.generate() == nil)
        }
        #expect(calls == 0)
        session.update(sourceText: "旧问题", preferences: .init())
        let old = try #require(session.generate())
        #expect(session.generate() == nil)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        session.cancel()
        session.update(sourceText: "新问题", preferences: .init())
        await session.generate()?.value
        pending.resume(returning: Self.output("迟到回复"))
        await old.value
        #expect(calls == 2)
        #expect(session.result?.text == "最新回复")
        #expect(session.result?.request.text == "新问题")
    }

    @Test func openingEditingToneAndCopyFollowReplyLifecycle() async throws {
        _ = NSApplication.shared
        let suite = "SmartReplyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [ReplyRequest] = []
        let session = SmartReplySession(defaults: defaults) { request in
            requests.append(request)
            return Self.output("请提供接口文档，我需要确认联调范围。")
        }
        let controller = SmartReplyWindowController(session: session)
        defer { controller.close() }
        controller.show(on: nil)
        #expect(requests.isEmpty && controller.sourceView.string.isEmpty)
        controller.sourceView.string = "今天可以完成接口联调吗？"
        controller.otherRoleField.stringValue = "项目经理"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(requests.isEmpty)
        controller.show(on: nil)
        #expect(controller.sourceView.string == "今天可以完成接口联调吗？")
        controller.content.runButton.performClick(nil)
        for _ in 0..<100 where session.isLoading { await Task.yield() }
        #expect(requests.count == 1)
        controller.myRoleField.stringValue = "技术负责人"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(requests.count == 1)
        controller.tonePicker.selectItem(at: 2)
        let action = try #require(controller.tonePicker.action)
        NSApp.sendAction(action, to: controller, from: controller.tonePicker)
        for _ in 0..<100 where session.isLoading { await Task.yield() }
        #expect(requests.count == 2)
        #expect(requests.last?.myRole == "技术负责人" && requests.last?.tone == .polite)
        #expect(requests.last?.text == "今天可以完成接口联调吗？")

        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(previous) }
        controller.content.copyButton.performClick(nil)
        #expect(pasteboard.string(forType: .string) == session.result?.text)
        #expect(controller.window?.isVisible == false)
        controller.show(on: nil)
        #expect(session.sourceText.isEmpty && session.result == nil && requests.count == 2)
        #expect(controller.myRoleField.stringValue == "技术负责人")
        pasteboard.clearContents()
        pasteboard.setString("手动粘贴的问题", forType: .string)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: controller.window!.windowNumber,
                                                 context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                                 isARepeat: false, keyCode: 9))
        #expect(controller.window!.performKeyEquivalent(with: event))
        #expect(session.sourceText == "手动粘贴的问题")
        controller.otherRoleField.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.tonePicker.selectItem(at: 3)
        NSApp.sendAction(action, to: controller, from: controller.tonePicker)
        #expect(requests.count == 2)
        controller.window?.cancelOperation(nil)
        #expect(controller.window?.isVisible == false)
    }

    @Test func bothNativePanelsFitThemesMinimumSizeAndScrollableContent() async throws {
        _ = NSApplication.shared
        let suite = "WritingPanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reply = SmartReplySession(defaults: defaults) { _ in Self.output("请提供接口文档和变更说明，便于确认联调范围。\n目前还需要确认接口的返回字段。") }
        let polish = ContentPolishSession(defaults: defaults) { _ in Self.output("商品列表页开发已完成。\n请在库存接口就绪后同步，方便继续联调与自测。") }
        let replyController = SmartReplyWindowController(session: reply)
        let polishController = ContentPolishWindowController(session: polish)
        defer { replyController.close(); polishController.close() }
        reply.update(sourceText: "库存接口今天可以开始联调吗？需要我们提供哪些资料？", preferences: .init())
        polish.open(sourceText: "商品列表页写完了，库存接口好了叫我一下，接着联调和自测。")
        await reply.generate()?.value
        await polish.polish()?.value
        for (name, window, view) in [("reply", replyController.window!, replyController.content),
                                    ("polish", polishController.window!, polishController.content)] {
            #expect(window.level == .normal && !window.hidesOnDeactivate)
            #expect(window.contentMinSize == NSSize(width: 600, height: 560))
            #expect(view.layer?.cornerRadius == 12)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for (width, height) in [(680.0, 600.0), (600.0, 560.0)] {
                    window.setContentSize(NSSize(width: width, height: height))
                    view.layoutSubtreeIfNeeded()
                    for control in [view.runButton, view.copyButton, view.statusLabel, view.sourceView.enclosingScrollView!,
                                    view.resultView.enclosingScrollView!] {
                        #expect(view.bounds.contains(control.convert(control.bounds, to: view)))
                        #expect(!control.hasAmbiguousLayout)
                    }
                    #expect(view.resultView.enclosingScrollView!.frame.height >= 50)
                    try Self.preview(view, name: "\(name)-\(theme)-\(Int(width))")
                }
            }
            view.updateFeedback(loading: false, status: "未完成", action: "重试", error: "模型响应超时，请稍后重试。", color: .systemRed)
            view.layoutSubtreeIfNeeded()
            #expect(view.resultView.enclosingScrollView!.frame.height >= 50)
            try Self.preview(view, name: "\(name)-error")
            view.sourceView.string = ""
            view.resultView.string = ""
            view.contextLabel.stringValue = "输入原文后开始生成"
            view.updateFeedback(loading: false, status: "等待输入", action: "开始生成")
            view.runButton.isEnabled = false
            view.copyButton.isEnabled = false
            view.layoutSubtreeIfNeeded()
            try Self.preview(view, name: "\(name)-empty")
            view.updateFeedback(loading: true, status: "正在生成…", action: "生成中")
            view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.cancelButton.frame))
            try Self.preview(view, name: "\(name)-loading")
            view.updateFeedback(loading: false, status: "等待输入", action: "开始生成")
        }
        let longText = String(repeating: "长回复保留全部段落，可以独立滚动查看。\n", count: 80)
        replyController.sourceView.string = longText
        replyController.resultView.string = longText
        replyController.content.layoutSubtreeIfNeeded()
        for text in [replyController.sourceView, replyController.resultView] {
            #expect(text.frame.height > text.enclosingScrollView!.contentSize.height)
        }
    }

    /// 仅显式设置产物目录时输出原生视图位图，供视觉检查，不替代真实鼠标验收。
    private static func preview(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WRITING_PREVIEW_DIRECTORY"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
