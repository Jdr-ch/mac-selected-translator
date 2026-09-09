import Foundation

/// A provider choice is app-owned; its model name and credentials remain CLI-owned.
enum ModelProvider: String, Codable, CaseIterable {
    case codex
    case qwen

    var title: String { self == .codex ? "Codex" : "Qwen" }
    var source: String { self == .codex ? "~/.codex/config.toml" : "~/.qwen/settings.json" }

    /// Qwen exposes a thinking switch; Codex exposes ordered effort levels.
    var reasoningOptions: [ModelReasoning] {
        self == .codex ? [.fastest, .medium, .high, .xhigh] : [.fastest, .thinking]
    }
}

/// App-owned request overrides, independent of both CLI configuration files.
enum ModelReasoning: String, Codable {
    case fastest
    case medium
    case high
    case xhigh
    case thinking

    /// Results use the short strength name; the picker additionally explains the fastest setting.
    var summaryTitle: String {
        switch self {
        case .fastest: return "最快"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "最高"
        case .thinking: return "深度思考"
        }
    }

    func title(for provider: ModelProvider) -> String {
        self == .fastest ? (provider == .codex ? "最快（低）" : "最快（关闭思考）") : summaryTitle
    }
}

/// The backend's public metadata deliberately contains no endpoint or authentication fields.
struct ModelInformation: Decodable, Equatable {
    let provider: ModelProvider
    let model: String
    let source: String
}

@MainActor
final class ModelSelectionStore {
    static let storageKey = "modelSelection.provider"
    private let defaults: UserDefaults
    private(set) var provider: ModelProvider
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Self.storageKey).flatMap(ModelProvider.init(rawValue:)) ?? .qwen
    }

    /// Only the global panel calls this; feature-local pickers keep a separate request choice.
    func select(_ provider: ModelProvider) {
        guard provider != self.provider else { return }
        self.provider = provider
        defaults.set(provider.rawValue, forKey: Self.storageKey)
        onChange?()
    }

    /// Each provider starts at fastest and retains only its own App preference between launches.
    func reasoning(for provider: ModelProvider) -> ModelReasoning {
        guard let rawValue = defaults.string(forKey: "modelSelection.reasoning.\(provider.rawValue)"),
              let value = ModelReasoning(rawValue: rawValue), provider.reasoningOptions.contains(value) else {
            return .fastest
        }
        return value
    }

    /// The global panel is the sole writer; feature requests only read an immutable value.
    func selectReasoning(_ reasoning: ModelReasoning) {
        guard provider.reasoningOptions.contains(reasoning) else { return }
        defaults.set(reasoning.rawValue, forKey: "modelSelection.reasoning.\(provider.rawValue)")
        onChange?()
    }
}

/// Loading is independent of selection: a broken config does not silently select another provider.
@MainActor
final class ModelSelectionSession {
    enum Phase: Equatable {
        case loading
        case loaded(ModelInformation)
        case failed(String)
    }

    let selection: ModelSelectionStore
    private(set) var phase: Phase = .loading
    var onChange: (() -> Void)?
    private let readModel: (ModelProvider) async throws -> ModelInformation
    private var task: Task<Void, Never>?
    /// Changes on every refresh/close so a previous tab's late response cannot overwrite this tab.
    private var requestID = UUID()

    init(selection: ModelSelectionStore,
         readModel: @escaping (ModelProvider) async throws -> ModelInformation) {
        self.selection = selection
        self.readModel = readModel
    }

    /// A tab action changes the global default immediately, then reloads its source configuration.
    @discardableResult
    func select(_ provider: ModelProvider) -> Task<Void, Never> {
        selection.select(provider)
        return refresh()
    }

    /// An App-only preference changes immediately without rereading or writing CLI metadata.
    func selectReasoning(_ reasoning: ModelReasoning) {
        selection.selectReasoning(reasoning)
        onChange?()
    }

    /// Reopening or refocusing the window reloads external edits without persisting model metadata.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        cancel()
        let id = requestID
        let provider = selection.provider
        phase = .loading
        onChange?()
        let task = Task { [weak self, readModel] in
            do {
                let information = try await readModel(provider)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                guard information.provider == provider, !information.model.isEmpty else {
                    throw TranslatorAppError.invalidBackendResponse
                }
                self.phase = .loaded(information)
                self.task = nil
                self.onChange?()
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
                self.task = nil
                self.onChange?()
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
    }
}
