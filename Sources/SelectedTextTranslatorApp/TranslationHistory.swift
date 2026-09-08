import Foundation

/// Retains successful selections and their original responses for local, request-free recall.
final class TranslationHistory {
    struct Entry: Codable, Equatable {
        let sourceText: String
        let translation: String
    }

    static let capacity = 5
    private static let userDefaultsKey = "translation.recentHistory"
    private let defaults: UserDefaults
    /// Newest translations come first; viewing an entry does not change translation order.
    private(set) var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.userDefaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(saved.prefix(Self.capacity))
    }

    /// Updates an exact source selection and evicts the oldest translation beyond the five-entry limit.
    func record(sourceText: String, translation: String) {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries.removeAll { $0.sourceText == source }
        entries.insert(Entry(sourceText: source, translation: translation), at: 0)
        entries = Array(entries.prefix(Self.capacity))
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
