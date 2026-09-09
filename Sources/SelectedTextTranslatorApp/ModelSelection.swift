import Foundation

/// A provider choice is app-owned; its model name and credentials remain CLI-owned.
enum ModelProvider: String, Codable, CaseIterable {
    case codex
    case qwen

    var title: String { self == .codex ? "Codex" : "Qwen" }
    var source: String { self == .codex ? "~/.codex/config.toml" : "~/.qwen/settings.json" }
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
