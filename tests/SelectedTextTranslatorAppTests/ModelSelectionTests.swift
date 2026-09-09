import AppKit
import Testing
@testable import SelectedTextTranslatorApp

/// Isolated defaults, an intercepted HTTP client and offscreen controls never touch CLI config files.
@Suite(.serialized)
@MainActor
struct ModelSelectionTests {
    @Test
    func selectionPersistsOnlyProviderAndReloadsMetadata() async throws {
        let name = "ModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelSelectionStore(defaults: defaults)
        #expect(store.provider == .qwen)
        var currentModel = "codex-first"
        var reads: [ModelProvider] = []
        let session = ModelSelectionSession(selection: store) { provider in
            reads.append(provider)
            return ModelInformation(provider: provider, model: currentModel, source: provider.source)
        }
        await session.select(.codex).value
        #expect(ModelSelectionStore(defaults: defaults).provider == .codex)
        #expect(defaults.persistentDomain(forName: name)?.count == 1)
        currentModel = "codex-external-edit"
        await session.refresh().value
        #expect(session.phase == .loaded(.init(provider: .codex, model: currentModel, source: ModelProvider.codex.source)))
        #expect(reads == [.codex, .codex])
    }

    @Test
    func rapidTabChangesIgnoreLateResponsesAndFailureKeepsChosenProvider() async throws {
        let name = "ModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelSelectionStore(defaults: defaults)
        var continuation: CheckedContinuation<ModelInformation, Error>?
        var shouldFail = false
        let session = ModelSelectionSession(selection: store) { provider in
            if shouldFail { throw TranslatorAppError.backendError("配置读取失败") }
            if provider == .codex {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return ModelInformation(provider: provider, model: "qwen-current", source: provider.source)
        }
        let old = session.select(.codex)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        await session.select(.qwen).value
        pending.resume(returning: .init(provider: .codex, model: "old-codex", source: ModelProvider.codex.source))
        await old.value
        #expect(store.provider == .qwen)
        #expect(session.phase == .loaded(.init(provider: .qwen, model: "qwen-current", source: ModelProvider.qwen.source)))
        shouldFail = true
        await session.select(.codex).value
        #expect(store.provider == .codex)
        #expect(session.phase == .failed("配置读取失败"))
    }

    @Test
    func httpRequestsCarryProviderAndRejectOldServiceCapabilities() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTestURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel(); ModelTestURLProtocol.respond = nil }
        var requests: [URLRequest] = []
        ModelTestURLProtocol.respond = { request in
            requests.append(request)
            switch request.url!.path {
            case "/models/codex": return Data(#"{"provider":"codex","model":"configured-model","source":"~/.codex/config.toml"}"#.utf8)
            case "/translate": return Data(#"{"translation":"译文"}"#.utf8)
            case "/flowchart":
                var response: [String: Any] = ["model": "configured-model", "ai_ms": 10]
                response["diagram"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FlowchartDocument.example))
                return try JSONSerialization.data(withJSONObject: response)
            default: return Data(#"{"polished_text":"润色结果"}"#.utf8)
            }
        }
        let client = BackendClient(urlSession: urlSession)
        #expect(try await client.modelInformation(for: .codex).model == "configured-model")
        #expect(try await client.translate("原文", targetLanguage: "auto", provider: .codex) == "译文")
        #expect(try await client.polish(.init(text: "原文", preferences: .init()), provider: .qwen) == "润色结果")
        let flowchart = FlowchartClient(configuration: AppConfiguration(), urlSession: urlSession)
        for provider in ModelProvider.allCases {
            #expect(try await flowchart.generate(text: "流程描述", provider: provider).diagram.steps.count == 7)
            let request = try #require(requests.last)
            let body = try #require(JSONSerialization.jsonObject(with: ModelTestURLProtocol.body(of: request)) as? [String: String])
            #expect(body == ["text": "流程描述", "provider": provider.rawValue])
        }
        let translation = try #require(JSONSerialization.jsonObject(with: ModelTestURLProtocol.body(of: requests[1])) as? [String: String])
        let polish = try #require(JSONSerialization.jsonObject(with: ModelTestURLProtocol.body(of: requests[2])) as? [String: String])
        #expect(translation["provider"] == "codex")
        #expect(polish["provider"] == "qwen")
        #expect(translation["api_key"] == nil && polish["api_key"] == nil)
        try BackendSupervisor.validateCapabilities(Data(#"{"ok":true,"capabilities":["model-switching"]}"#.utf8))
        #expect(throws: TranslatorAppError.self) {
            try BackendSupervisor.validateCapabilities(Data(#"{"ok":true,"model":"qwen-old"}"#.utf8))
        }
    }

    @Test
    func nativePanelHasTwoReadOnlyTabsAndStableLayout() async throws {
        _ = NSApplication.shared
        let name = "ModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelSelectionStore(defaults: defaults)
        let session = ModelSelectionSession(selection: store) { provider in
            .init(provider: provider, model: provider == .codex ? "gpt-6-astra" : "qwen3.7-max", source: provider.source)
        }
        let controller = ModelSelectionWindowController(session: session)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        #expect(controller.tabs.map(\.title) == ["Codex", "Qwen"])
        #expect(!controller.modelLabel.isEditable && !controller.sourceLabel.isEditable)
        #expect(window.canBecomeKey)
        for (index, provider) in ModelProvider.allCases.enumerated() {
            controller.tabs[index].performClick(nil)
            for _ in 0..<100 where session.phase == .loading { await Task.yield() }
            #expect(store.provider == provider)
            #expect(controller.sourceLabel.stringValue == provider.source)
            #expect(controller.modelLabel.stringValue == (provider == .codex ? "gpt-6-astra" : "qwen3.7-max"))
            content.layoutSubtreeIfNeeded()
            for view in (controller.tabs as [NSView]) + [controller.modelLabel, controller.sourceLabel, controller.defaultLabel] {
                let frame = view.convert(view.bounds, to: content)
                #expect(content.bounds.contains(frame))
                #expect(frame.height > 10)
            }
            let modelFrame = controller.modelLabel.convert(controller.modelLabel.bounds, to: content)
            let defaultFrame = controller.defaultLabel.convert(controller.defaultLabel.bounds, to: content)
            #expect(modelFrame.maxX < defaultFrame.minX)
            // Optional bitmaps are test artifacts; no installed app, login item or real config is changed.
            if let path = ProcessInfo.processInfo.environment["MODEL_PANEL_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("\(provider.rawValue)-\(appearance.rawValue).png"))
                }
            }
        }
        controller.close()
    }
}

/// Intercepts every test URL before networking; request bodies may be delivered as streams by URLSession.
private final class ModelTestURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var request = request
            request.httpBody = Self.body(of: request)
            let data = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
