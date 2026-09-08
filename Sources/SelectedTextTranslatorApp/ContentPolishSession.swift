import Foundation

/// Owns one editable polishing session independently of translation and native window focus.
@MainActor
final class ContentPolishSession {
    enum Phase: Equatable {
        case idle
        case loading
        case error(String)
    }

    private(set) var sourceText = ""
    private(set) var preferences: PolishPreferences
    private(set) var result: PolishResult?
    private(set) var phase: Phase = .idle
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let requestPolish: (PolishRequest) async throws -> String
    private var requestTask: Task<Void, Never>?
    /// Invalidated on cancel/open so a late network response cannot replace the current session.
    private var requestID = UUID()

    init(
        defaults: UserDefaults = .standard,
        requestPolish: @escaping (PolishRequest) async throws -> String
    ) {
        self.defaults = defaults
        self.preferences = PolishPreferences.load(from: defaults)
        self.requestPolish = requestPolish
    }

    var currentRequest: PolishRequest {
        PolishRequest(text: sourceText, preferences: preferences)
    }

    var isLoading: Bool { phase == .loading }

    /// A result retains its original context label while the user edits the next request.
    var isDirty: Bool {
        guard let result else { return false }
        return result.request != currentRequest
    }

    /// Starts a new selection without carrying an unrelated result or request into the window.
    func open(sourceText: String, captureError: String? = nil) {
        cancel()
        self.sourceText = sourceText
        result = nil
        phase = captureError.map(Phase.error) ?? .idle
        onChange?()
    }

    /// Edits are allowed between requests; existing output remains available for copying.
    func update(sourceText: String, preferences: PolishPreferences) {
        guard !isLoading else { return }
        self.sourceText = sourceText
        self.preferences = preferences
        phase = .idle
        onChange?()
    }

    /// Submits the original text with the current context and remembers settings only on success.
    @discardableResult
    func polish() -> Task<Void, Never>? {
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
                let text = try await requestPolish(request)
                guard requestID == id, !Task.isCancelled else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslatorAppError.backendError("模型返回了空润色结果，请重试。")
                }
                result = PolishResult(request: request, text: text)
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

    /// Cancels the local request and ignores late completion; any previous result is preserved.
    func cancel() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        phase = .idle
        onChange?()
    }
}
