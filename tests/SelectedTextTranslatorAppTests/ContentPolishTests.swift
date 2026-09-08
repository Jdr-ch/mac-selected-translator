import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// Uses isolated preferences and offscreen native controls; never reads the user's real selection.
@Suite(.serialized)
@MainActor
struct ContentPolishTests {
    @Test
    func rewritesOriginalWithUpdatedContextAndRemembersSuccessfulPreferences() async throws {
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [PolishRequest] = []
        let session = ContentPolishSession(defaults: defaults) { request in
            requests.append(request)
            return "润色后的完整内容\n第二段"
        }
        #expect(session.preferences == PolishPreferences())
        session.open(sourceText: " 原始内容\n第二段 ")
        await session.polish()?.value
        session.update(sourceText: session.sourceText, preferences: .init(role: "产品经理", scenario: "周报", tone: .concise))
        #expect(session.isDirty)
        #expect(session.result?.request.tone == .professional)
        await session.polish()?.value
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.text == "原始内容\n第二段" })
        #expect(requests.last?.tone == .concise)
        #expect(!session.isDirty)
        #expect(PolishPreferences.load(from: defaults) == session.preferences)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(requests[1])) as? [String: String])
        #expect(json == ["text": "原始内容\n第二段", "role": "产品经理", "scenario": "周报", "tone": "concise"])
        #expect(defaults.dictionaryRepresentation()["contentPolish.sourceText"] == nil)
    }

    @Test
    func cancellingIgnoresLateResultsAndPreventsDuplicateRequests() async throws {
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<String, Error>?
        var calls = 0
        let session = ContentPolishSession(defaults: defaults) { _ in
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return "当前结果"
        }
        session.open(sourceText: "原文")
        let firstTask = try #require(session.polish())
        #expect(session.polish() == nil)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        session.cancel()
        session.update(sourceText: "新的原文", preferences: .init(tone: .formal))
        await session.polish()?.value
        pending.resume(returning: "过期结果")
        await firstTask.value
        #expect(calls == 2)
        #expect(session.result?.text == "当前结果")
        #expect(session.result?.request.text == "新的原文")
        #expect(session.phase == .idle)
    }

    @Test
    func validationAndFailurePreservePreviousResult() async throws {
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var shouldFail = false
        let session = ContentPolishSession(defaults: defaults) { _ in
            if shouldFail { throw TranslatorAppError.backendError("请求失败，请重试。") }
            return "上次结果"
        }
        session.open(sourceText: "原文")
        await session.polish()?.value
        session.update(sourceText: "原文", preferences: .init(role: "", scenario: "办公", tone: .polite))
        #expect(session.polish() == nil)
        #expect(session.phase == .error("请填写角色。"))
        session.update(sourceText: "原文", preferences: .init(tone: .polite))
        shouldFail = true
        await session.polish()?.value
        #expect(session.phase == .error("请求失败，请重试。"))
        #expect(session.result?.text == "上次结果")
        #expect(PolishPreferences.load(from: defaults).tone == .professional)
    }

    @Test
    func nativeWindowMatchesFieldsAndCopiesFullScrollableResult() async throws {
        _ = NSApplication.shared
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var output = "商品列表页开发已完成。\n请在库存接口就绪后同步，我会完成联调与自测。"
        let session = ContentPolishSession(defaults: defaults) { _ in output }
        let controller = ContentPolishWindowController(session: session)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        #expect(window.canBecomeKey)
        #expect(controller.roleField.stringValue == "前端开发工程师")
        #expect(controller.scenarioField.stringValue == "办公")
        #expect(controller.tonePicker.itemTitles == PolishTone.allCases.map(\.title))
        #expect(controller.tonePicker.titleOfSelectedItem == "专业清晰")
        #expect(controller.copyButton.title.isEmpty)
        #expect(controller.copyButton.imagePosition == .imageOnly)
        let closeButton = try #require(content.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "关闭" })
        #expect(closeButton.title.isEmpty)
        session.open(sourceText: "商品列表页写完了，库存接口好了叫我一下，我再联调和自测。")
        await session.polish()?.value
        content.layoutSubtreeIfNeeded()
        #expect(controller.resultView.string == output)
        #expect(!controller.resultView.isEditable)
        #expect(controller.sourceView.isEditable)
        for width in [680.0, 600.0] {
            window.setContentSize(NSSize(width: width, height: 540))
            content.layoutSubtreeIfNeeded()
            for view in [controller.roleField, controller.scenarioField, controller.tonePicker, controller.runButton, controller.copyButton] {
                let frame = view.convert(view.bounds, to: content)
                #expect(content.bounds.contains(frame))
                #expect(frame.width > 30)
            }
            #expect(controller.sourceView.enclosingScrollView!.frame.maxY < content.bounds.maxY)
            #expect(controller.resultView.enclosingScrollView!.frame.height >= 50)
            let pickerFrame = controller.tonePicker.convert(controller.tonePicker.bounds, to: content)
            #expect(abs(pickerFrame.maxX - (content.bounds.maxX - 20)) < 1)
        }
        let pasteboard = NSPasteboard.general
        let oldItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(oldItems) }
        window.makeKeyAndOrderFront(nil)
        controller.copyButton.performClick(nil)
        #expect(pasteboard.string(forType: .string) == output)
        #expect(session.result?.text == output)
        #expect(!window.isVisible)

        // Optional offscreen rendering supports visual inspection without launching the installed app.
        if let path = ProcessInfo.processInfo.environment["POLISH_PREVIEW_PATH"] {
            window.setContentSize(NSSize(width: 680, height: 540))
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }

        // Standard paste must reach the editable source even without an application Edit menu.
        pasteboard.clearContents()
        pasteboard.setString("手动粘贴的原文", forType: .string)
        window.makeFirstResponder(controller.sourceView)
        controller.sourceView.selectAll(nil)
        let paste = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        #expect(window.performKeyEquivalent(with: paste))
        #expect(controller.sourceView.string == "手动粘贴的原文")
        #expect(session.sourceText == "手动粘贴的原文")

        output = String(repeating: "长段落仍应完整保留，支持滚动查看。\n", count: 80)
        session.open(sourceText: output)
        await session.polish()?.value
        content.layoutSubtreeIfNeeded()
        let resultScroll = try #require(controller.resultView.enclosingScrollView)
        #expect(controller.resultView.frame.height > resultScroll.contentSize.height)
        controller.copyButton.performClick(nil)
        #expect(pasteboard.string(forType: .string) == output)
    }

    @Test
    func toneSelectionImmediatelySubmitsCurrentSourceAndContext() async throws {
        _ = NSApplication.shared
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [PolishRequest] = []
        let session = ContentPolishSession(defaults: defaults) { request in
            requests.append(request)
            return "本次结果"
        }
        let controller = ContentPolishWindowController(session: session)
        session.open(sourceText: "保持原始片段")
        await session.polish()?.value

        // 角色和场景仍只更新草稿，预期下拉框才是自动提交入口。
        controller.roleField.stringValue = "产品经理"
        controller.scenarioField.stringValue = "周报"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(requests.count == 1)
        let toneAction = try #require(controller.tonePicker.action)
        controller.tonePicker.selectItem(at: try #require(PolishTone.allCases.firstIndex(of: .polite)))
        #expect(NSApp.sendAction(toneAction, to: controller.tonePicker.target, from: controller.tonePicker))
        #expect(session.isLoading)
        for _ in 0..<100 where session.isLoading { await Task.yield() }
        #expect(!session.isLoading)
        #expect(requests.count == 2)
        #expect(requests.last == PolishRequest(text: "保持原始片段", preferences: .init(role: "产品经理", scenario: "周报", tone: .polite)))
        #expect(session.result?.request.tone == .polite)

        // 同一选项的重复 action 和空原文场景均不得调用模型。
        #expect(NSApp.sendAction(toneAction, to: controller.tonePicker.target, from: controller.tonePicker))
        #expect(!session.isLoading)
        session.open(sourceText: "")
        controller.tonePicker.selectItem(at: try #require(PolishTone.allCases.firstIndex(of: .concise)))
        #expect(NSApp.sendAction(toneAction, to: controller.tonePicker.target, from: controller.tonePicker))
        #expect(session.preferences.tone == .concise)
        #expect(session.phase == .idle)
        #expect(requests.count == 2)
    }

    @Test
    func sourceFocusSurvivesAutomaticRequestInNormalLevelWindow() async throws {
        _ = NSApplication.shared
        let suite = "ContentPolishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ContentPolishSession(defaults: defaults) { _ in "润色结果" }
        let controller = ContentPolishWindowController(session: session)
        let panel = try #require(controller.window as? NSPanel)
        #expect(panel.level == .normal)
        #expect(!panel.isFloatingPanel)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.initialFirstResponder === controller.sourceView)

        // 离屏走打开时的焦点步骤，检查请求前后均保持原文为第一响应者。
        session.open(sourceText: "原文含补充字符：𠮷")
        let task = try #require(session.polish())
        controller.focusSourceText()
        #expect(panel.firstResponder === controller.sourceView)
        #expect(controller.sourceView.selectedRange() == NSRange(location: session.sourceText.utf16.count, length: 0))
        await task.value
        #expect(panel.firstResponder === controller.sourceView)
        #expect(controller.sourceView.isEditable)

        session.open(sourceText: "")
        controller.focusSourceText()
        #expect(panel.firstResponder === controller.sourceView)
        #expect(controller.sourceView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test
    func failedCopyCannotReuseStaleClipboardText() {
        #expect(AccessibilitySelectionReader.copiedSelection("旧剪贴板", before: 4, after: 4) == nil)
        #expect(AccessibilitySelectionReader.copiedSelection("新选区", before: 4, after: 5) == "新选区")
    }
}
