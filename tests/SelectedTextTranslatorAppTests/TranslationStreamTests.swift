import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// Exercises chunk boundaries and incomplete requests without changing real model settings.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TranslationStreamTests {
    @Test
    func splitHeadersAndPartialSecondaryLinesStayOutOfPrimary() throws {
        for prefix in ["", "主", "主译", "主译：", "unstructured draft"] {
            #expect(TranslationStreamPreview(response: prefix) == nil)
        }
        let primary = try #require(TranslationStreamPreview(response: "主译：你"))
        #expect(primary.presentation.primaryTranslation == "你")
        #expect(!primary.canCopyPrimary)
        for tail in ["音", "音标", "候", "候选"] {
            let preview = try #require(TranslationStreamPreview(response: "主译：你好\n" + tail))
            #expect(preview.presentation.primaryTranslation == "你好")
            #expect(preview.presentation.pronunciation == nil)
            #expect(preview.presentation.candidates.isEmpty)
        }
        let prefix = "主译：你好\n音标：hello /həˈloʊ/"
        let pending = try #require(TranslationStreamPreview(response: prefix))
        #expect(pending.canCopyPrimary)
        #expect(pending.presentation.pronunciation == nil)
        let completeIPA = try #require(TranslationStreamPreview(response: prefix + "\n候选：\n- 您好（礼"))
        #expect(completeIPA.presentation.pronunciation?.word == "hello")
        #expect(completeIPA.presentation.candidates.isEmpty)
        let completeCandidate = try #require(TranslationStreamPreview(response: prefix + "\n候选：\n- 您好（礼貌）\n- 你好"))
        #expect(completeCandidate.presentation.candidates == [.init(term: "您好", context: "礼貌")])
        #expect(TranslationStreamPreview(response: "主译: line one\nline two")?.presentation.primaryTranslation == "line one\nline two")
    }

    /// The mock cannot finish until the consumer observes the first visible primary text.
    @Test(arguments: ["complete", "error", "eof", "cancel"])
    @MainActor
    func primaryArrivesBeforeTerminalEventAndCancellationStopsTransport(ending: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            TranslationTestURLProtocol.start = nil
            TranslationTestURLProtocol.stop = nil
        }
        let stopped = AsyncStream<Void>.makeStream()
        TranslationTestURLProtocol.stop = { stopped.continuation.yield(()) }
        var transport: TranslationTestURLProtocol?
        TranslationTestURLProtocol.start = { current in
            transport = current
            current.send(#"{"type":"delta","text":"主译：你"}"#)
        }
        var previews: [TranslationStreamPreview] = []
        var task: Task<ModelTextResult, Error>?
        task = Task { @MainActor in
            try await BackendClient(urlSession: session).translate("hello", targetLanguage: "auto",
                                                                   provider: .codex, reasoning: .fastest) { preview in
                previews.append(preview)
                switch ending {
                case "complete": transport?.send(#"{"type":"complete","translation":"主译：你好","ai_ms":15}"#)
                case "error": transport?.send(#"{"type":"error","error":"上游中断"}"#)
                case "eof": transport?.client?.urlProtocolDidFinishLoading(transport!)
                default: task?.cancel()
                }
            }
        }
        do {
            let result = try await task!.value
            #expect(ending == "complete")
            #expect(result.text == "主译：你好")
            #expect(result.completion.aiMS == 15)
        } catch {
            #expect(ending != "complete")
            if ending == "cancel" { #expect(error is CancellationError) }
            if ending == "error" { #expect(error.localizedDescription.contains("上游中断")) }
            if ending == "eof" { #expect(error.localizedDescription.contains("连接已中断")) }
        }
        #expect(previews.map(\.presentation.primaryTranslation) == ["你"])
        if ending != "eof" {
            for await _ in stopped.stream { break }
        }
        stopped.continuation.finish()
    }

    /// Native layout remains anchored while only successful terminal output enters history.
    @Test @MainActor
    func streamingPanelKeepsAnchorAndScrollWithoutRecordingDrafts() throws {
        _ = NSApplication.shared
        let suite = "TranslationStreamTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingPanelController(defaults: defaults)
        controller.showResult("主译：旧译文", sourceText: "old")
        controller.showLoading("正在翻译...")
        let window = try #require(controller.completionLabel.window)
        defer { window.orderOut(nil) }
        let screen = try #require(window.screen)
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.maxY - 80))
        let top = window.frame.maxY
        let x = window.frame.minX
        let content = try #require(window.contentView)
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let history = try #require(content.subviews.compactMap { $0 as? TranslationHistoryView }.first)
        controller.showStreamingResult(try #require(TranslationStreamPreview(response: "主译：你好")))
        #expect(controller.completionLabel.stringValue == "正在翻译...")
        #expect(scroll.documentView?.subviews.compactMap { $0 as? PrimaryTranslationCopyButton }.first?.isEnabled == false)
        let response = "主译：你好\n音标：hello /həˈloʊ/\n候选：\n" + String(repeating: "- 您好（礼貌问候）\n", count: 25)
        controller.showStreamingResult(try #require(TranslationStreamPreview(response: response)))
        #expect(controller.completionLabel.stringValue == "正在补全...")
        #expect(window.frame.maxY == top && window.frame.minX == x)
        #expect(window.frame.height == 360)
        #expect(content.bounds.contains(controller.completionLabel.frame))
        #expect(controller.completionLabel.frame.maxY <= scroll.frame.minY)
        #expect(history.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        controller.showStreamingResult(try #require(TranslationStreamPreview(response: response + "- 嗨\n")))
        #expect(scroll.contentView.bounds.origin.y == 40)
        #expect(TranslationHistory(defaults: defaults).entries.map(\.sourceText) == ["old"])
        var dismissed = false
        controller.onDismiss = { dismissed = true }
        let close = try #require(content.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "关闭" })
        close.performClick(nil)
        #expect(dismissed && !window.isVisible)
        controller.showResult(response, sourceText: "hello", followsMouse: false)
        #expect(TranslationHistory(defaults: defaults).entries.map(\.sourceText) == ["hello", "old"])
    }
}

/// Lets tests gate a URLSession byte stream without sleeping or making external requests.
private final class TranslationTestURLProtocol: URLProtocol {
    static var start: ((TranslationTestURLProtocol) -> Void)?
    static var stop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let health = request.url?.path == "/health"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": health ? "application/json" : "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if health {
            send(#"{"request_timeout_seconds":120}"#)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            Self.start?(self)
        }
    }

    func send(_ line: String) {
        client?.urlProtocol(self, didLoad: Data((line + "\n").utf8))
    }

    override func stopLoading() {
        if request.url?.path == "/translate" { Self.stop?() }
    }
}
