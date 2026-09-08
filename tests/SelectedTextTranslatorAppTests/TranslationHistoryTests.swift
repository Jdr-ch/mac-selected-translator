import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// Checks local recall with isolated preferences and native controls, without opening the installed app.
struct TranslationHistoryTests {
    @Test
    func retainsFiveRecentTranslationsAndRestoresUpdatedResults() throws {
        let suiteName = "TranslationHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = TranslationHistory(defaults: defaults)
        #expect(history.entries.isEmpty)

        for source in ["one", "two", "three", "four", "five", "six"] {
            history.record(sourceText: source, translation: "主译：\(source)")
        }
        #expect(history.entries.map(\.sourceText) == ["six", "five", "four", "three", "two"])

        let response = "主译：二\n音标：two /tuː/\n候选：\n- 两个（数量）"
        history.record(sourceText: " two ", translation: response)
        let restored = TranslationHistory(defaults: defaults)
        #expect(restored.entries.map(\.sourceText) == ["two", "six", "five", "four", "three"])
        #expect(restored.entries.first?.translation == response)
        #expect(restored.entries == history.entries)
    }

    @Test
    @MainActor
    func historyControlsRecallFullResultsWithinOneCompactRow() throws {
        _ = NSApplication.shared
        let entries = (1...5).map { index in
            TranslationHistory.Entry(
                sourceText: "selected source \(index) with a long context",
                translation: "主译：译文 \(index)\n音标：word /wɜːd/\n候选：\n- 候选（解释）"
            )
        }
        let frame = NSRect(x: 0, y: 0, width: 420, height: TranslationHistoryView.preferredHeight)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let view = TranslationHistoryView(frame: frame)
        window.contentView = view
        var recalled: TranslationHistory.Entry?
        view.onSelect = { recalled = $0 }
        view.update(entries: entries, selectedSourceText: entries[0].sourceText, isEnabled: true)
        view.layoutSubtreeIfNeeded()

        let buttons = view.subviews.compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
        #expect(buttons.count == 5)
        #expect(!view.isHidden)
        for (index, button) in buttons.enumerated() {
            #expect(view.bounds.contains(button.frame))
            #expect(button.toolTip == entries[index].sourceText)
            if index > 0 {
                #expect(buttons[index - 1].frame.maxX < button.frame.minX)
            }
        }

        let button = try #require(buttons.last)
        button.performClick(nil)
        #expect(recalled == entries.last)
        let presentation = TranslationResultPresentation(response: try #require(recalled).translation)
        #expect(presentation.primaryTranslation == "译文 5")
        #expect(presentation.pronunciation?.phonetic == "/wɜːd/")
        #expect(presentation.candidates == [.init(term: "候选", context: "解释")])

        view.update(entries: entries, selectedSourceText: nil, isEnabled: false)
        #expect(view.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled })
        view.update(entries: [], selectedSourceText: nil, isEnabled: true)
        #expect(view.isHidden)
    }
}
