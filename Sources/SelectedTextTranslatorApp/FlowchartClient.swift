import Foundation

/// Uses the existing local service; provider secrets never enter the rendering page.
struct FlowchartClient {
    let configuration: AppConfiguration
    var urlSession: URLSession = .shared

    /// Supplies the optional per-diagram model without changing the backend's default model.
    func generate(text: String, model: String?) async throws -> FlowchartResponse {
        struct Request: Encodable { let text: String; let model: String? }
        var request = URLRequest(url: configuration.backendBaseURL.appendingPathComponent("flowchart"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(text: text, model: model))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FlowchartError.message("流程图服务返回了无法识别的响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            throw FlowchartError.message(message ?? "流程图服务返回 HTTP \(http.statusCode)。")
        }
        let result = try JSONDecoder().decode(FlowchartResponse.self, from: data)
        try result.diagram.validate()
        return result
    }

    /// The existing health endpoint exposes the default model without exposing its credentials.
    func defaultModel() async throws -> String {
        struct Health: Decodable { let model: String }
        var request = URLRequest(url: configuration.healthURL)
        request.timeoutInterval = 2
        let (data, _) = try await urlSession.data(for: request)
        return try JSONDecoder().decode(Health.self, from: data).model
    }
}
