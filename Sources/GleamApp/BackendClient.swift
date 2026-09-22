import Foundation

struct BackendClient {
    private let endpoint: URL
    private let polishEndpoint: URL
    private let modelsEndpoint: URL
    private let healthURL: URL
    private let urlSession: URLSession

    init(configuration: AppConfiguration = AppConfiguration(), urlSession: URLSession = .shared) {
        self.endpoint = configuration.translateURL
        self.polishEndpoint = configuration.backendBaseURL.appendingPathComponent("polish")
        self.modelsEndpoint = configuration.backendBaseURL.appendingPathComponent("models")
        self.healthURL = configuration.healthURL
        self.urlSession = urlSession
    }

    /// Sends selected text to the local LangChain backend.
    ///
    /// The Python service resolves the chosen CLI configuration for each request;
    /// model credentials never enter the native UI or the local request body.
    func translate(_ text: String, targetLanguage: String, provider: ModelProvider,
                   reasoning: ModelReasoning,
                   onProgress: @escaping @MainActor (TranslationStreamPreview) -> Void = { _ in }) async throws -> ModelTextResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Short translations may make a second model call to complete IPA.
        request.timeoutInterval = try await BackendRequestTimeout.load(from: healthURL, modelCalls: 2, session: urlSession)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            TranslateRequest(text: text, targetLanguage: targetLanguage, provider: provider, reasoning: reasoning, stream: true)
        )

        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslatorAppError.invalidBackendResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
                throw TranslatorAppError.backendError(message ?? "翻译服务返回 HTTP \(httpResponse.statusCode)。")
            }

            guard httpResponse.mimeType == "application/x-ndjson" else {
                throw TranslatorAppError.backendError("当前本地服务不支持流式翻译，请退出 App 后重新启动。")
            }
            var accumulated = ""
            var lastPreview: TranslationStreamPreview?
            var lastUpdate = ContinuousClock.now
            for try await line in bytes.lines where !line.isEmpty {
                try Task.checkCancellation()
                let event = try JSONDecoder().decode(TranslationStreamEvent.self, from: Data(line.utf8))
                switch event.type {
                case .delta:
                    guard let text = event.text else { throw TranslatorAppError.invalidBackendResponse }
                    accumulated += text
                    // Flush completed lines immediately; cap intermediate token layout work at 25 FPS.
                    if lastPreview == nil || text.contains("\n") || lastUpdate.duration(to: .now) >= .milliseconds(40),
                       let preview = TranslationStreamPreview(response: accumulated), preview != lastPreview {
                        await onProgress(preview)
                        lastPreview = preview
                        lastUpdate = .now
                    }
                case .complete:
                    guard let text = event.translation, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let aiMS = event.aiMS, aiMS.isFinite, aiMS >= 0 else {
                        throw TranslatorAppError.invalidBackendResponse
                    }
                    return ModelTextResult(text: text,
                                           completion: ModelCompletion(provider: provider, reasoning: reasoning, aiMS: aiMS))
                case .error:
                    throw TranslatorAppError.backendError(event.error ?? "翻译请求中断，请重试。")
                }
            }
            throw TranslatorAppError.backendError("翻译连接已中断，请重试。")
        } catch let error as TranslatorAppError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranslatorAppError.backendNotReachable(error.localizedDescription)
        }
    }

    /// Sends a source/context snapshot to the same local model service without translation parsing.
    func polish(_ payload: PolishRequest, provider: ModelProvider, reasoning: ModelReasoning) async throws -> ModelTextResult {
        var request = URLRequest(url: polishEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = try await BackendRequestTimeout.load(from: healthURL, modelCalls: 1, session: urlSession)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PolishRequest(text: payload.text, preferences: payload.preferences, provider: provider, reasoning: reasoning)
        )

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw TranslatorAppError.invalidBackendResponse
            }
            if response.statusCode == 404 {
                throw TranslatorAppError.backendError("当前本地服务尚未支持内容润色，请重启本地服务后重试。")
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
                throw TranslatorAppError.backendError(message ?? "润色服务返回 HTTP \(response.statusCode)。")
            }
            let result = try JSONDecoder().decode(PolishResponse.self, from: data)
            return ModelTextResult(text: result.polishedText,
                                   completion: ModelCompletion(provider: provider, reasoning: reasoning, aiMS: result.aiMS))
        } catch let error as TranslatorAppError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranslatorAppError.backendError("无法完成润色请求：\(error.localizedDescription)")
        }
    }

    /// Read only the selected provider's public metadata after the supervisor has ensured readiness.
    func modelInformation(for provider: ModelProvider) async throws -> ModelInformation {
        var request = URLRequest(url: modelsEndpoint.appendingPathComponent(provider.rawValue))
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TranslatorAppError.invalidBackendResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            throw TranslatorAppError.backendError(message ?? "模型配置读取失败，请检查 \(provider.source)。")
        }
        return try JSONDecoder().decode(ModelInformation.self, from: data)
    }
}

/// Translation, polishing and diagrams all derive their HTTP deadline from the same runtime setting.
enum BackendRequestTimeout {
    static func load(from healthURL: URL, modelCalls: Int, session: URLSession) async throws -> TimeInterval {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw TranslatorAppError.invalidBackendResponse
        }
        return try JSONDecoder().decode(BackendHealth.self, from: data).requestTimeout(modelCalls: modelCalls)
    }
}
