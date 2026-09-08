import Foundation

/// One ordered step shared by the backend, editor, and both SVG templates.
struct FlowchartStep: Codable, Equatable, Identifiable {
    // Editor identity stays stable during reordering; it is not part of the model's wire format.
    var id = UUID()
    var title: String
    var description: String
    var kind: String
    var iconID: String
    var nextLabel: String

    enum CodingKeys: String, CodingKey {
        case title, description, kind
        case iconID = "icon_id"
        case nextLabel = "next_label"
    }
}

/// Presentation-independent content; style changes never regenerate this document.
struct FlowchartDocument: Codable, Equatable {
    var title: String
    var subtitle: String
    var steps: [FlowchartStep]

    static var empty: FlowchartDocument { .init(title: "", subtitle: "", steps: []) }

    /// Reference content for exported examples and tests, never a substitute for a live AI response.
    static var example: FlowchartDocument {
        FlowchartDocument(title: "编译型语言的执行过程", subtitle: "从源代码到可执行程序", steps: [
            .init(title: "语言文件", description: "源代码 · .c / .cpp", kind: "artifact", iconID: "file-text", nextLabel: "输入"),
            .init(title: "编译器", description: "将源代码转换为汇编代码", kind: "process", iconID: "settings", nextLabel: "编译"),
            .init(title: "汇编代码", description: "汇编指令 · .s / .asm", kind: "artifact", iconID: "code", nextLabel: "输入"),
            .init(title: "汇编器", description: "将汇编指令转换为机器码", kind: "process", iconID: "cpu", nextLabel: "汇编"),
            .init(title: "二进制机器码", description: "目标文件 · .o / .obj", kind: "artifact", iconID: "file-text", nextLabel: "输入"),
            .init(title: "链接器", description: "合并目标文件并解析外部符号", kind: "process", iconID: "link", nextLabel: "链接"),
            .init(title: "可执行exe文件", description: "可由操作系统加载运行的程序", kind: "result", iconID: "play", nextLabel: "")
        ])
    }

    /// Reject invalid wire documents before replacing the user's current editable result.
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !steps.isEmpty else {
            throw FlowchartError.message("流程图需要标题和至少一个步骤。")
        }
        let kinds = ["artifact", "process", "result"]
        let icons = ["file-text", "cpu", "code", "settings", "link", "play", "check"]
        guard steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && kinds.contains($0.kind) && icons.contains($0.iconID) }) else {
            throw FlowchartError.message("流程步骤的名称、类型或图标不正确。")
        }
    }
}

struct FlowchartResponse: Codable {
    let diagram: FlowchartDocument
    let model: String
    /// Upstream model duration in milliseconds; local rendering is measured independently.
    let aiMS: Double

    enum CodingKeys: String, CodingKey {
        case diagram, model
        case aiMS = "ai_ms"
    }
}

enum FlowchartStyle: String, Codable, CaseIterable {
    case horizontal
    case staircase

    var title: String { self == .horizontal ? "深色横向" : "立体阶梯" }
}

enum FlowchartError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
