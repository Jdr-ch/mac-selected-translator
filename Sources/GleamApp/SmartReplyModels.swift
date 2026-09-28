import Foundation

/// 回复偏好独立于润色保存；对方原文和生成结果不进入 UserDefaults。
struct ReplyPreferences: Codable, Equatable {
    var myRole = "前端开发工程师"
    var otherRole = "同事"
    var scenario = "办公"
    var tone: PolishTone = .professional

    static let storageKey = "smartReply.preferences"

    /// 初次使用或旧记录不可解码时使用产品默认身份。
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    /// 仅在生成成功后调用，避免无效或未提交的草稿污染下次默认值。
    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// /reply 的不可变输入快照；text 始终为对方原文，不能使用上次生成的回复。
struct ReplyRequest: Encodable, Equatable {
    let text: String
    let myRole: String
    let otherRole: String
    let scenario: String
    let tone: PolishTone
    let provider: ModelProvider?
    let reasoning: ModelReasoning?

    enum CodingKeys: String, CodingKey {
        case text, scenario, tone, provider, reasoning
        case myRole = "my_role"
        case otherRole = "other_role"
    }

    init(text: String, preferences: ReplyPreferences, provider: ModelProvider? = nil,
         reasoning: ModelReasoning? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        myRole = preferences.myRole.trimmingCharacters(in: .whitespacesAndNewlines)
        otherRole = preferences.otherRole.trimmingCharacters(in: .whitespacesAndNewlines)
        scenario = preferences.scenario.trimmingCharacters(in: .whitespacesAndNewlines)
        tone = preferences.tone
        self.provider = provider
        self.reasoning = reasoning
    }

    /// 与 Python 按 Unicode 标量计数保持一致，必填校验阻止无身份方向的生成。
    var validationMessage: String? {
        if text.isEmpty { return "请填写对方原文。" }
        for (label, value) in [("我的角色", myRole), ("对方角色", otherRole), ("场景", scenario)] {
            if value.isEmpty { return "请填写\(label)。" }
            if value.unicodeScalars.count > 100 { return "\(label)不能超过 100 个字符。" }
        }
        return nil
    }

    var preferences: ReplyPreferences {
        ReplyPreferences(myRole: myRole, otherRole: otherRole, scenario: scenario, tone: tone)
    }

    /// 结果携带当次身份方向，后续草稿修改不会改写旧结果的上下文。
    var contextDescription: String { "\(myRole) → \(otherRole) · \(scenario) · \(tone.title)" }
}

/// 后端只返回正文及毫秒耗时，模型信息取自此次请求的配置快照。
struct ReplyResponse: Decodable {
    let replyText: String
    let aiMS: Double

    enum CodingKeys: String, CodingKey {
        case replyText = "reply_text"
        case aiMS = "ai_ms"
    }
}

struct ReplyResult: Equatable {
    let request: ReplyRequest
    let text: String
    let completion: ModelCompletion
}
