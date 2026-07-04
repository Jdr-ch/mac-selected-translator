import Foundation

struct BackendClient {
    private let endpoint: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let rawBaseURL = environment["TRANSLATOR_BACKEND_URL"] ?? "http://127.0.0.1:8765"
        let baseURL = rawBaseURL.hasSuffix("/") ? String(rawBaseURL.dropLast()) : rawBaseURL
        self.endpoint = URL(string: "\(baseURL)/translate")!
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
}
