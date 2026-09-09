import Foundation

/// Uses the existing local service; provider secrets never enter the rendering page.
struct FlowchartClient {
    let configuration: AppConfiguration
    var urlSession: URLSession = .shared

    /// Sends only the local provider choice; the service resolves its CLI-owned configuration.
    func generate(text: String, provider: ModelProvider) async throws -> FlowchartResponse {
        struct Request: Encodable { let text: String; let provider: ModelProvider }
        var request = URLRequest(url: configuration.backendBaseURL.appendingPathComponent("flowchart"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(text: text, provider: provider))
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
}
