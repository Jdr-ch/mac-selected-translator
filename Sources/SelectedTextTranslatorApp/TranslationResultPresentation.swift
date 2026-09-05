import Foundation

/// Converts the backend's stable plain-text response into the sections rendered by the macOS popup.
struct TranslationResultPresentation: Equatable {
    struct Pronunciation: Equatable {
        let word: String?
        let phonetic: String
    }

    struct Candidate: Equatable {
        let term: String
        let context: String?
    }

    let primaryTranslation: String
    let pronunciation: Pronunciation?
    let candidates: [Candidate]

    /// Parses the labeled response while retaining a readable fallback for older unstructured replies.
    init(response: String) {
        enum Section {
            case primary
            case pronunciation
            case candidates
        }

        var section: Section?
        var primaryLines: [String] = []
        var pronunciationLines: [String] = []
        var parsedCandidates: [Candidate] = []
        var foundStructuredSection = false

        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            if let value = Self.value(after: "主译", in: line) {
                foundStructuredSection = true
                section = .primary
                if !value.isEmpty {
                    primaryLines.append(value)
                }
                continue
            }

            if let value = Self.value(after: "音标", in: line) {
                foundStructuredSection = true
                section = .pronunciation
                if !value.isEmpty {
                    pronunciationLines.append(value)
                }
                continue
            }

            if let value = Self.value(after: "候选", in: line) {
                foundStructuredSection = true
                section = .candidates
                if let candidate = Self.parseCandidate(value) {
                    parsedCandidates.append(candidate)
                }
                continue
            }

            switch section {
            case .primary:
                primaryLines.append(line)
            case .pronunciation:
                pronunciationLines.append(line)
            case .candidates:
                if let candidate = Self.parseCandidate(line) {
                    parsedCandidates.append(candidate)
                }
            case nil:
                primaryLines.append(line)
            }
        }

        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        primaryTranslation = primaryLines.isEmpty && !foundStructuredSection
            ? trimmedResponse
            : primaryLines.joined(separator: "\n")

        let pronunciationText = pronunciationLines.joined(separator: " ")
        pronunciation = Self.parsePronunciation(pronunciationText)
        candidates = parsedCandidates
    }

    /// Accepts both Chinese and English colons without broadening the backend response contract.
    private static func value(after label: String, in line: String) -> String? {
        for separator in ["：", ":"] {
            let prefix = label + separator
            guard line.hasPrefix(prefix) else {
                continue
            }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Splits the pronunciation word from the slash-delimited phonetic spelling used by the backend.
    private static func parsePronunciation(_ value: String) -> Pronunciation? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let slashIndex = trimmed.firstIndex(of: "/") else {
            return Pronunciation(word: nil, phonetic: trimmed)
        }

        let word = String(trimmed[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let phonetic = String(trimmed[slashIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Pronunciation(word: word.isEmpty ? nil : word, phonetic: phonetic)
    }

    /// Extracts the copyable term and optional explanatory context from one candidate bullet.
    private static func parseCandidate(_ value: String) -> Candidate? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = candidate.first, marker == "-" || marker == "•" || marker == "·" {
            candidate.removeFirst()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !candidate.isEmpty else {
            return nil
        }

        for pair in [("（", "）"), ("(", ")")] {
            guard
                let openingRange = candidate.range(of: pair.0),
                candidate.hasSuffix(pair.1)
            else {
                continue
            }

            let term = String(candidate[..<openingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contextStart = openingRange.upperBound
            let contextEnd = candidate.index(candidate.endIndex, offsetBy: -pair.1.count)
            let context = String(candidate[contextStart..<contextEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !term.isEmpty else {
                return nil
            }
            return Candidate(term: term, context: context.isEmpty ? nil : context)
        }

        return Candidate(term: candidate, context: nil)
    }
}

/// Keeps candidate-copy payloads on the existing private URL scheme used by the popup interaction.
enum TranslationCandidateLink {
    static let scheme = "selected-translator-candidate"

    /// Encodes a candidate as a private URL that can be attached to an AppKit control.
    static func url(for candidate: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "copy"
        components.queryItems = [URLQueryItem(name: "text", value: candidate)]
        return components.url
    }

    /// Decodes only this app's candidate-copy URLs and rejects empty payloads.
    static func candidate(from url: URL) -> String? {
        guard
            url.scheme == scheme,
            let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "text" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !candidate.isEmpty
        else {
            return nil
        }

        return candidate
    }
}
