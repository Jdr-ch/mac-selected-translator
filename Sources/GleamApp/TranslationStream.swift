import Foundation

/// Local HTTP events contain answer text only; completion replaces any unvalidated partial answer.
struct TranslationStreamEvent: Decodable {
    enum Kind: String, Decodable { case delta, complete, error }
    let type: Kind
    let text: String?
    let translation: String?
    let aiMS: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, text, translation, error
        case aiMS = "ai_ms"
    }
}

/// Main text can grow per chunk; IPA and candidates appear only after their line is complete.
struct TranslationStreamPreview: Equatable {
    let presentation: TranslationResultPresentation
    let canCopyPrimary: Bool

    init?(response: String) {
        let lines = response.components(separatedBy: "\n")
        let tail = lines.last ?? ""
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryHeaders = ["音标：", "音标:", "候选：", "候选:"]
        canCopyPrimary = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return secondaryHeaders.contains { trimmed.hasPrefix($0) }
        }
        var visibleLines = Array(lines.dropLast())
        let headers = ["主译：", "主译:"] + secondaryHeaders
        let pendingHeader = headers.contains { $0.hasPrefix(trimmedTail) }
        if !canCopyPrimary, !pendingHeader { visibleLines.append(tail) }
        let visible = visibleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.hasPrefix("主译：") || visible.hasPrefix("主译:") else { return nil }
        presentation = TranslationResultPresentation(response: visible)
        guard !presentation.primaryTranslation.isEmpty else { return nil }
    }
}
