import Foundation

enum TranslatorAppError: LocalizedError {
    case accessibilityPermissionMissing
    case noSelectedText
    case backendNotReachable(String)
    case backendProjectRootMissing
    case backendStartupFailed(String)
    case invalidBackendResponse
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "需要在 系统设置 > 隐私与安全性 > 辅助功能 中允许当前终端或 App。"
        case .noSelectedText:
            return "没有读取到选中文字。请先在当前 App 中选中一段文字，再按 Option+Tab。"
        case .backendNotReachable(let detail):
            return "无法连接本地翻译服务：\(detail)"
        case .backendProjectRootMissing:
            return "缺少项目路径配置。请通过 scripts/build_app.sh 重新生成 App，或设置 TRANSLATOR_PROJECT_ROOT。"
        case .backendStartupFailed(let detail):
            return "本地翻译服务启动失败：\(detail)"
        case .invalidBackendResponse:
            return "本地翻译服务返回格式不正确。"
        case .backendError(let message):
            return message
        }
    }
}

struct TranslateRequest: Encodable {
    let text: String
    let targetLanguage: String
    let provider: ModelProvider
    let reasoning: ModelReasoning
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case text
        case provider
        case reasoning
        case stream
        case targetLanguage = "target_language"
    }
}

struct ErrorResponse: Decodable {
    let error: String?
}

/// Runtime timing is read from the service so CLI reasoning cannot outlive a shorter UI deadline.
struct BackendHealth: Decodable {
    let capabilities: [String]?
    let requestTimeoutSeconds: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case capabilities
        case requestTimeoutSeconds = "request_timeout_seconds"
    }

    func requestTimeout(modelCalls: Int) throws -> TimeInterval {
        guard let seconds = requestTimeoutSeconds, seconds.isFinite, seconds > 0 else {
            throw TranslatorAppError.backendError("当前本地服务需要更新，请退出 App 后重新启动。")
        }
        return seconds * Double(modelCalls) + 5
    }
}
