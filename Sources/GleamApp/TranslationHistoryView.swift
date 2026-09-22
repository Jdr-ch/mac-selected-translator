import AppKit

/// Keeps all five recent selections visible in a fixed-height footer outside the result scroll area.
@MainActor
final class TranslationHistoryView: NSView {
    static let preferredHeight: CGFloat = 38
    var onSelect: ((TranslationHistory.Entry) -> Void)?

    private let separator = NSBox()
    private let titleLabel = NSTextField(labelWithString: "历史")
    private var entries: [TranslationHistory.Entry] = []
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(separator)
        addSubview(titleLabel)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Uses the full source as the action payload while truncating only the single-line display title.
    func update(entries: [TranslationHistory.Entry], selectedSourceText: String?, isEnabled: Bool) {
        self.entries = entries
        buttons.forEach { $0.removeFromSuperview() }
        buttons = entries.enumerated().map { index, entry in
            let title = entry.sourceText.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            let button = NSButton(title: title, target: self, action: #selector(selectEntry(_:)))
            button.tag = index
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.font = .systemFont(ofSize: 12, weight: entry.sourceText == selectedSourceText ? .semibold : .regular)
            button.contentTintColor = entry.sourceText == selectedSourceText ? .controlAccentColor : .labelColor
            button.lineBreakMode = .byTruncatingTail
            button.cell?.usesSingleLineMode = true
            button.toolTip = entry.sourceText
            button.setAccessibilityLabel("查看历史翻译：\(entry.sourceText)")
            button.isEnabled = isEnabled
            addSubview(button)
            return button
        }
        isHidden = entries.isEmpty
        needsLayout = true
    }

    /// Reserves equal click targets so long selections cannot push neighboring history entries out of view.
    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        titleLabel.frame = NSRect(x: 18, y: (bounds.height - 16) / 2, width: 28, height: 16)
        let leading: CGFloat = 54
        let spacing: CGFloat = 4
        let count = CGFloat(max(buttons.count, 1))
        let width = max(0, (bounds.width - leading - 18 - spacing * (count - 1)) / count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: leading + CGFloat(index) * (width + spacing),
                y: (bounds.height - 26) / 2,
                width: width,
                height: 26
            )
        }
    }

    /// Recalls the captured result without copying text or starting another backend request.
    @objc private func selectEntry(_ sender: NSButton) {
        guard sender.isEnabled, entries.indices.contains(sender.tag) else {
            return
        }
        onSelect?(entries[sender.tag])
    }
}
