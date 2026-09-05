import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// Locks the backend-text presentation contract without opening a real AppKit panel.
struct TranslationResultPresentationTests {
    /// Verifies one-line candidates use the compact row while wrapped context still receives padding.
    @Test
    func candidateRowsUseCompactHeight() {
        #expect(CandidateRowLayout.preferredHeight(textHeight: 17) == 30)
        #expect(CandidateRowLayout.preferredHeight(textHeight: 34) == 40)
    }

    /// Verifies the backend's standard response is split into the three approved visual sections.
    @Test
    func parsesStructuredTranslationSections() {
        let presentation = TranslationResultPresentation(
            response: """
            主译：标准化的；规范化的
            音标：standardized /ˈstændərdaɪzd/
            候选：
            - 规范化（强调过程）
            - 标准化（强调结果）
            """
        )

        #expect(presentation.primaryTranslation == "标准化的；规范化的")
        #expect(presentation.pronunciation == .init(
            word: "standardized",
            phonetic: "/ˈstændərdaɪzd/"
        ))
        #expect(presentation.candidates == [
            .init(term: "规范化", context: "强调过程"),
            .init(term: "标准化", context: "强调结果")
        ])
    }

    /// Verifies colon variants and legacy plain-text replies remain readable in the redesigned popup.
    @Test
    func acceptsEnglishColonsAndKeepsUnstructuredRepliesReadable() {
        let structured = TranslationResultPresentation(
            response: "主译: translated\n音标: /trænzˈleɪtɪd/\n候选:\n• 已翻译"
        )
        let fallback = TranslationResultPresentation(response: "本地翻译服务已就绪。")

        #expect(structured.primaryTranslation == "translated")
        #expect(structured.pronunciation == .init(word: nil, phonetic: "/trænzˈleɪtɪd/"))
        #expect(structured.candidates == [.init(term: "已翻译", context: nil)])
        #expect(fallback.primaryTranslation == "本地翻译服务已就绪。")
    }

    /// Verifies Unicode candidate text still uses the existing private link scheme without loss.
    @Test
    func candidateLinkPreservesSchemeAndRoundTripsUnicodeText() throws {
        let url = try #require(TranslationCandidateLink.url(for: "规范化 / normalized"))

        #expect(url.scheme == "selected-translator-candidate")
        #expect(TranslationCandidateLink.candidate(from: url) == "规范化 / normalized")
        #expect(TranslationCandidateLink.candidate(from: URL(string: "https://example.com")!) == nil)
    }
}
