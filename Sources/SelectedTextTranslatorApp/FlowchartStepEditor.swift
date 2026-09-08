import AppKit

/// Scroll documents start at step one instead of AppKit's default bottom-left origin.
@MainActor
final class FlowchartStepListView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A compact editable step row; stable IDs keep edits and reorder actions attached to the same step.
@MainActor
final class FlowchartStepEditor: NSStackView, NSTextFieldDelegate {
    let stepID: UUID
    private let titleField = NSTextField(string: "")
    private let descriptionField = NSTextField(string: "")
    private let numberLabel = NSTextField(labelWithString: "")
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let deleteButton = NSButton()
    var onEdit: ((UUID, String, String) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onDelete: ((UUID) -> Void)?

    init(step: FlowchartStep) {
        stepID = step.id
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.placeholderString = "步骤名称"
        descriptionField.placeholderString = "步骤说明"
        titleField.delegate = self
        descriptionField.delegate = self
        for (button, symbol, tooltip, action) in [
            (upButton, "arrow.up", "上移", #selector(moveStepUp)),
            (downButton, "arrow.down", "下移", #selector(moveStepDown)),
            (deleteButton, "trash", "删除步骤", #selector(removeStep))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.toolTip = tooltip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        }
        let header = NSStackView(views: [numberLabel, titleField, upButton, downButton, deleteButton])
        header.spacing = 4
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(header)
        addArrangedSubview(descriptionField)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        descriptionField.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Avoid assigning unchanged strings so live preview updates do not reset the field editor cursor.
    func update(step: FlowchartStep, index: Int, count: Int, enabled: Bool) {
        if titleField.stringValue != step.title { titleField.stringValue = step.title }
        if descriptionField.stringValue != step.description { descriptionField.stringValue = step.description }
        numberLabel.stringValue = String(format: "%02d", index + 1)
        titleField.isEnabled = enabled
        descriptionField.isEnabled = enabled
        upButton.isEnabled = enabled && index > 0
        downButton.isEnabled = enabled && index < count - 1
        deleteButton.isEnabled = enabled && count > 1
    }

    func controlTextDidChange(_ obj: Notification) {
        onEdit?(stepID, titleField.stringValue, descriptionField.stringValue)
    }

    @objc private func moveStepUp() { onMove?(stepID, -1) }
    @objc private func moveStepDown() { onMove?(stepID, 1) }
    @objc private func removeStep() { onDelete?(stepID) }
}
