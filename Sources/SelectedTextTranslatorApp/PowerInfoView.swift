import AppKit

/// 左栏只显示共享快照，不自行读取电源；通过格式化结果去重标签更新。
@MainActor
final class PowerInfoView: NSVisualEffectView {
    var onShowPowerChange: ((Bool) -> Void)?
    private let percentage = NSTextField(labelWithString: "—")
    private let status = NSTextField(labelWithString: "电源状态暂不可用")
    private let adapter = NSTextField(wrappingLabelWithString: "暂不可用")
    private let adapterRating = NSTextField(labelWithString: "")
    private let level = PowerLevelView()
    private let contractValue = NSTextField(labelWithString: "—")
    private let inputVoltageValue = NSTextField(labelWithString: "—")
    private let inputWattsValue = NSTextField(labelWithString: "—")
    private let batteryVoltageValue = NSTextField(labelWithString: "—")
    private let chargingValue = NSTextField(labelWithString: "—")
    private let chargingLabel = NSTextField(labelWithString: "电池充电功率")
    private let inputRows = NSStackView()
    private var batteryRow: NSView!
    private var chargingRow: NSView!
    private let powerCheckbox = NSButton(checkboxWithTitle: "功率", target: nil, action: nil)
    private var lastPresentation: PowerPresentation?
    private var currentState = PowerState.unavailable

    init(showPower: Bool) {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        let heading = NSTextField(labelWithString: "电源监控")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(heading)
        percentage.font = .monospacedDigitSystemFont(ofSize: 31, weight: .medium)
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        let top = NSStackView(views: [percentage, NSView(), status])
        top.alignment = .firstBaseline
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(level)
        level.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        level.heightAnchor.constraint(equalToConstant: 5).isActive = true
        let adapterLabel = Self.secondaryLabel("充电器")
        stack.addArrangedSubview(adapterLabel)
        adapter.font = .systemFont(ofSize: 12, weight: .medium)
        adapter.maximumNumberOfLines = 3
        stack.addArrangedSubview(adapter)
        adapter.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        adapterRating.font = .systemFont(ofSize: 11)
        adapterRating.textColor = .secondaryLabelColor
        stack.addArrangedSubview(adapterRating)
        stack.setCustomSpacing(4, after: adapterLabel)
        stack.setCustomSpacing(4, after: adapter)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        inputRows.orientation = .vertical
        inputRows.alignment = .leading
        inputRows.spacing = 14
        for (label, value) in [("供电档位", contractValue), ("系统输入电压", inputVoltageValue), ("系统输入功率", inputWattsValue)] {
            let row = Self.row(label: Self.secondaryLabel(label), value: value)
            inputRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inputRows.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(inputRows)
        inputRows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        batteryRow = Self.row(label: Self.secondaryLabel("电池自身电压"), value: batteryVoltageValue)
        chargingLabel.font = .systemFont(ofSize: 11)
        chargingLabel.textColor = .secondaryLabelColor
        chargingRow = Self.row(label: chargingLabel, value: chargingValue)
        for row in [batteryRow!, chargingRow!] {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        powerCheckbox.state = showPower ? .on : .off
        powerCheckbox.font = .systemFont(ofSize: 11)
        powerCheckbox.target = self
        powerCheckbox.action = #selector(powerVisibilityChanged)
        powerCheckbox.setAccessibilityLabel("菜单栏显示功率")
        let options = NSStackView(views: [Self.secondaryLabel("菜单栏显示"), NSView(), powerCheckbox])
        stack.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只有可见文案变化才设置文本；电量条使用真实百分比，不制造周期动画。
    func update(snapshot: PowerSnapshot, presentation: PowerPresentation) {
        level.fraction = (snapshot.batteryPercent ?? 0) / 100
        guard lastPresentation != presentation else { return }
        lastPresentation = presentation
        currentState = presentation.state
        percentage.stringValue = presentation.percent
        status.stringValue = presentation.state.title
        adapter.stringValue = presentation.adapter
        adapterRating.stringValue = presentation.adapterRating
        adapterRating.isHidden = !presentation.showAdapter
        inputRows.isHidden = !presentation.showAdapter
        batteryRow.isHidden = !presentation.showBattery
        chargingRow.isHidden = !presentation.showAdapter
        contractValue.stringValue = presentation.contract
        inputVoltageValue.stringValue = presentation.inputVoltage
        inputWattsValue.stringValue = presentation.inputWatts
        batteryVoltageValue.stringValue = presentation.batteryVoltage
        chargingLabel.stringValue = presentation.state == .charging ? "电池充电功率" : "电池状态"
        chargingValue.stringValue = presentation.state == .charging ? presentation.chargingWatts : presentation.state.title
        chargingValue.toolTip = presentation.state == .charging ? "按电池包电压 × 电池电流估算；系统输入功率包含电脑运行消耗。" : nil
        refreshColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        status.textColor = PowerIconStyle.color(for: currentState, dark: dark)
        level.fillColor = status.textColor ?? .systemBlue
    }

    /// 原生勾选只通知展示偏好变化，由上层复用快照更新菜单栏，不触发采集。
    @objc private func powerVisibilityChanged() {
        onShowPowerChange?(powerCheckbox.state == .on)
    }

    private static func secondaryLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 标签和值分开设置压缩优先级，输入值采用等宽数字，长设备名在单独的多行区域显示。
    private static func row(label: NSTextField, value: NSTextField) -> NSStackView {
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, NSView(), value])
        row.spacing = 5
        row.alignment = .firstBaseline
        return row
    }
}

/// 五点高的静态电量条，仅数值或主题改变时重绘。
@MainActor
private final class PowerLevelView: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var fillColor = NSColor.systemBlue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        fillColor.setFill()
        let width = bounds.width * min(1, max(0, fraction))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
    }
}
