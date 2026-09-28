import Foundation

/// 回复业务会话独立于润色；控制器只转交编辑草稿和用户触发的生成动作。
@MainActor
final class SmartReplySession {
    enum Phase: Equatable {
        case idle
        case loading
        case error(String)
    }

    private(set) var sourceText = ""
    private(set) var preferences: ReplyPreferences
    private(set) var result: ReplyResult?
    private(set) var phase: Phase = .idle
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let requestReply: (ReplyRequest) async throws -> ModelTextResult
    private var requestTask: Task<Void, Never>?
    /// 取消或重新打开时失效，防止晚到的模型结果覆盖新草稿。
    private var requestID = UUID()

    init(defaults: UserDefaults = .standard,
         requestReply: @escaping (ReplyRequest) async throws -> ModelTextResult) {
        self.defaults = defaults
        preferences = ReplyPreferences.load(from: defaults)
        self.requestReply = requestReply
    }

    var currentRequest: ReplyRequest { ReplyRequest(text: sourceText, preferences: preferences) }
    var isLoading: Bool { phase == .loading }
    var isDirty: Bool { result.map { $0.request != currentRequest } ?? false }

    /// 新开窗口只恢复成功保存的参数，清空文本，不读取选区也不触发模型。
    func open() {
        cancel()
        sourceText = ""
        result = nil
        preferences = ReplyPreferences.load(from: defaults)
        onChange?()
    }

    /// 编辑时保留可复制的旧结果；请求中锁住输入避免响应与当前参数错配。
    func update(sourceText: String, preferences: ReplyPreferences) {
        guard !isLoading else { return }
        self.sourceText = sourceText
        self.preferences = preferences
        phase = .idle
        onChange?()
    }

    /// 使用当前原文和双方身份生成；重试也不将旧回复作为新原文。
    @discardableResult
    func generate() -> Task<Void, Never>? {
        guard !isLoading else { return nil }
        let request = currentRequest
        if let message = request.validationMessage {
            phase = .error(message)
            onChange?()
            return nil
        }
        let id = UUID()
        requestID = id
        phase = .loading
        onChange?()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await requestReply(request)
                guard requestID == id, !Task.isCancelled else { return }
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslatorAppError.backendError("模型返回了空回复，请重试。")
                }
                result = ReplyResult(request: request, text: response.text, completion: response.completion)
                preferences = request.preferences
                preferences.save(to: defaults)
                phase = .idle
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
            requestTask = nil
            onChange?()
        }
        requestTask = task
        return task
    }

    /// 取消只停止当前请求，失败或取消后仍可复制上次成功结果。
    func cancel() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        phase = .idle
        onChange?()
    }
}
