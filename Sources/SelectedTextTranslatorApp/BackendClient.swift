import Foundation

struct BackendClient {
    private let endpoint: URL
    private let polishEndpoint: URL

    init(configuration: AppConfiguration = AppConfiguration()) {
        self.endpoint = configuration.translateURL
        self.polishEndpoint = configuration.backendBaseURL.appendingPathComponent("polish")
    }

    /// Sends selected text to the local LangChain backend.
    ///
    /// The Swift app never calls the Qwen endpoint directly. Keeping model calls
    /// inside the Python service avoids duplicating provider-specific request
    /// fields in two languages and lets users change model settings through
    /// `.env` without rebuilding the macOS app.
    func translate(_ text: String, targetLanguage: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TranslateRequest(text: text, targetLanguage: targetLanguage)
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslatorAppError.invalidBackendResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
                throw TranslatorAppError.backendError(message ?? "翻译服务返回 HTTP \(httpResponse.statusCode)。")
            }

            let payload = try JSONDecoder().decode(TranslateResponse.self, from: data)
            return payload.translation
        } catch let error as TranslatorAppError {
            throw error
        } catch {
            throw TranslatorAppError.backendNotReachable(error.localizedDescription)
        }
    }

    /// Sends a source/context snapshot to the same local model service without translation parsing.
    func polish(_ payload: PolishRequest) async throws -> String {
        var request = URLRequest(url: polishEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 65
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
            return try JSONDecoder().decode(PolishResponse.self, from: data).polishedText
        } catch let error as TranslatorAppError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranslatorAppError.backendError("无法完成润色请求：\(error.localizedDescription)")
        }
    }
}
