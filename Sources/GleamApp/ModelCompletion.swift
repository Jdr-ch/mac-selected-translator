import Foundation

/// Metadata belongs to the completed request, never to the currently selected global model.
struct ModelCompletion: Codable, Equatable {
    let provider: ModelProvider
    let reasoning: ModelReasoning
    /// Backend generation time in milliseconds, including translation's optional IPA retry.
    let aiMS: Double

    /// All three tools share one compact label; unavailable timing must not be presented as zero.
    func status(_ action: String) -> String {
        let model = "\(action)·\(provider.rawValue)-\(reasoning.summaryTitle)"
        guard aiMS.isFinite, aiMS >= 0 else { return "\(model) 耗时未知" }
        let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), aiMS / 1000)
        return "\(model) \(seconds)秒"
    }
}

/// Text remains separate from completion metadata so copy actions never include the status label.
struct ModelTextResult: Equatable {
    let text: String
    let completion: ModelCompletion
}
