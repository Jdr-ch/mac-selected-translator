import Foundation

/// Owns editor persistence and generation cancellation independently of translation and polishing.
@MainActor
final class FlowchartSession {
    struct SavedState: Codable {
        var input: String
        var document: FlowchartDocument
        var style: FlowchartStyle
    }

    private(set) var state: SavedState
    private(set) var provider: ModelProvider
    private var isPresented = false
    private(set) var isGenerating = false
    private(set) var status = ""
    private(set) var hasError = false
    private(set) var lastAIMS: Double?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let defaultProvider: () -> ModelProvider
    private let generateResponse: (String, ModelProvider) async throws -> FlowchartResponse
    private var task: Task<Void, Never>?
    // Each cancel/new generation invalidates late results even when the upstream call cannot stop.
    private var generation = 0
    private static let storageKey = "flowchart.document.v1"

    init(defaults: UserDefaults = .standard,
         defaultProvider: @escaping () -> ModelProvider = { .qwen },
         generateResponse: @escaping (String, ModelProvider) async throws -> FlowchartResponse) {
        self.defaults = defaults
        self.defaultProvider = defaultProvider
        provider = defaultProvider()
        self.generateResponse = generateResponse
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            state = saved
        } else {
            state = SavedState(input: "", document: .empty, style: .horizontal)
        }
        if Self.isUntouchedExample(state) {
            state.input = ""
            state.document = .empty
            persist()
        }
    }

    /// Remove only the old bundled seed; edited documents and style choices survive.
    private static func isUntouchedExample(_ saved: SavedState) -> Bool {
        guard saved.input == "描述编译型语言的执行过程：语言文件-编译器-汇编代码-汇编器-二进制机器码-链接器-可执行exe文件" else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let content = try? encoder.encode(saved.document),
              let example = try? encoder.encode(FlowchartDocument.example) else { return false }
        return content == example
    }

    /// Persist user edits immediately; changing the input alone does not replace the current result.
    func edit(_ update: (inout SavedState) -> Void) {
        update(&state)
        persist()
        onChange?()
    }

    /// Follow the global choice once per opening, preserving local selection when brought forward.
    func beginPresentation() {
        guard !isPresented else { return }
        isPresented = true
        selectProvider(defaultProvider())
    }

    func endPresentation() {
        isPresented = false
        cancel()
    }

    /// This choice lives only in the editor session and never writes global preferences.
    func selectProvider(_ provider: ModelProvider) {
        self.provider = provider
        onChange?()
    }

    /// Generate once from a snapshot; only the still-current request may publish a new document.
    func generate() {
        guard !isGenerating else { return }
        let input = state.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            report("请输入流程描述。", isError: true)
            return
        }
        let provider = self.provider
        generation += 1
        let requestGeneration = generation
        isGenerating = true
        report("正在理解流程…", isError: false)
        task = Task { [weak self, generateResponse] in
            do {
                let result = try await generateResponse(input, provider)
                try Task.checkCancellation()
                try result.diagram.validate()
                guard let self, self.generation == requestGeneration else { return }
                self.state.document = result.diagram
                self.lastAIMS = result.aiMS
                self.isGenerating = false
                self.task = nil
                self.persist()
                self.report("已生成 · AI \(String(format: "%.2f", result.aiMS / 1000)) 秒", isError: false)
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.isGenerating = false
                self.task = nil
                self.report(error is CancellationError ? "已取消" : error.localizedDescription,
                            isError: !(error is CancellationError))
            }
        }
    }

    /// Stop waiting and preserve the last editable document, including on window close.
    func cancel() {
        guard isGenerating else { return }
        generation += 1
        task?.cancel()
        task = nil
        isGenerating = false
        report("已取消", isError: false)
    }

    /// Reorder by stable editor identity so duplicate step titles remain independent.
    func moveStep(id: UUID, offset: Int) {
        guard let index = state.document.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard state.document.steps.indices.contains(destination) else { return }
        edit { $0.document.steps.swapAt(index, destination) }
    }

    /// Publish export or service failures in the same visible status area without erasing content.
    func report(_ message: String, isError: Bool) {
        status = message
        hasError = isError
        onChange?()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
