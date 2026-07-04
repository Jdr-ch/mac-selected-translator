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

    enum CodingKeys: String, CodingKey {
        case text
        case targetLanguage = "target_language"
    }
}

struct TranslateResponse: Decodable {
    let translation: String
}

struct ErrorResponse: Decodable {
    let error: String?
}
