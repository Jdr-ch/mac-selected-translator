import Foundation

/// Stable API values shared by the tone picker, saved preferences, and /polish requests.
enum PolishTone: String, Codable, CaseIterable {
    case professional
    case concise
    case polite
    case friendly
    case formal
    case assertive

    var title: String {
        switch self {
        case .professional: return "专业清晰"
        case .concise: return "简洁直接"
        case .polite: return "礼貌委婉"
        case .friendly: return "自然友好"
        case .formal: return "正式严谨"
        case .assertive: return "坚定明确"
        }
    }
}

/// Only successful request settings are persisted; source text and model output stay in memory.
struct PolishPreferences: Codable, Equatable {
    var role = "前端开发工程师"
    var scenario = "办公"
    var tone: PolishTone = .professional

    static let storageKey = "contentPolish.preferences"

    /// Uses the approved defaults until a complete saved preference record exists.
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return saved
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// An immutable source/settings snapshot prevents retries from rewriting a previous result.
struct PolishRequest: Encodable, Equatable {
    let text: String
    let role: String
    let scenario: String
    let tone: PolishTone
    /// Added only at the HTTP boundary; session draft/result equality stays provider-independent.
    let provider: ModelProvider?

    init(text: String, preferences: PolishPreferences, provider: ModelProvider? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = preferences.role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scenario = preferences.scenario.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tone = preferences.tone
        self.provider = provider
    }

    /// Mirrors the required fields and 100-character context limit in the local API.
    var validationMessage: String? {
        if text.isEmpty { return "请填写原文。" }
        if role.isEmpty { return "请填写角色。" }
        if scenario.isEmpty { return "请填写场景。" }
        if role.unicodeScalars.count > 100 { return "角色不能超过 100 个字符。" }
        if scenario.unicodeScalars.count > 100 { return "场景不能超过 100 个字符。" }
        return nil
    }

    var preferences: PolishPreferences {
        PolishPreferences(role: role, scenario: scenario, tone: tone)
    }

    var contextDescription: String {
        "\(role) · \(scenario) · \(tone.title)"
    }
}

struct PolishResponse: Decodable {
    let polishedText: String

    enum CodingKeys: String, CodingKey {
        case polishedText = "polished_text"
    }
}

struct PolishResult: Equatable {
    let request: PolishRequest
    let text: String
}
