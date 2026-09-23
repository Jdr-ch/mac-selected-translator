import AppKit

/// 左栏只显示共享快照，不自行读取电源；通过格式化结果去重标签更新。
@MainActor
final class PowerInfoView: NSVisualEffectView {
    var onShowPowerChange: ((Bool) -> Void)?
    var onShowPowerHistory: (([PowerHistorySample], NSView) -> Void)?
    var onShowBatteryHistory: (([BatteryHistorySample], NSView) -> Void)?
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
    private let inputPowerRow = PowerMetricRowView(label: "系统输入功率")
    private let batteryStateRow = PowerMetricRowView(label: "电池状态")
    private var batteryRow: NSView!
    private var chargingRow: NSView!
    private let powerCheckbox = NSButton(checkboxWithTitle: "功率", target: nil, action: nil)
    private var lastPresentation: PowerPresentation?
    private var currentState = PowerState.unavailable
    private var history: [PowerHistorySample] = []
    private var batteryHistory: [BatteryHistorySample] = []

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
        for (label, value) in [("供电档位", contractValue), ("系统输入电压", inputVoltageValue)] {
            let row = Self.row(label: Self.secondaryLabel(label), value: value)
            inputRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inputRows.widthAnchor).isActive = true
        }
        inputPowerRow.value = inputWattsValue.stringValue
        inputPowerRow.onActivate = { [weak self] in self?.toggleHistoryChart() }
        inputRows.addArrangedSubview(inputPowerRow)
        inputPowerRow.widthAnchor.constraint(equalTo: inputRows.widthAnchor).isActive = true
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
        batteryStateRow.isInteractive = true
        batteryStateRow.toolTip = "查看最近两小时电量与充电时段"
        batteryStateRow.onActivate = { [weak self] in
            guard let self else { return }
            self.onShowBatteryHistory?(self.batteryHistory, self.batteryStateRow)
        }
        stack.addArrangedSubview(batteryStateRow)
        batteryStateRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
    func update(snapshot: PowerSnapshot, presentation: PowerPresentation, history: [PowerHistorySample] = []) {
        level.fraction = (snapshot.batteryPercent ?? 0) / 100
        updateHistory(history)
        guard lastPresentation != presentation else { return }
        lastPresentation = presentation
        currentState = presentation.state
        percentage.stringValue = presentation.percent
        status.stringValue = presentation.state.title
        adapter.stringValue = presentation.adapter
        adapterRating.stringValue = presentation.adapterRating
        adapterRating.isHidden = !presentation.showAdapter
        inputRows.isHidden = !presentation.showAdapter
        inputPowerRow.value = presentation.inputWatts
        inputPowerRow.isInteractive = presentation.showAdapter && snapshot.inputWatts?.isFinite == true
        batteryRow.isHidden = !presentation.showBattery
        chargingRow.isHidden = presentation.state != .charging
        batteryStateRow.value = presentation.state.title
        contractValue.stringValue = presentation.contract
        inputVoltageValue.stringValue = presentation.inputVoltage
        inputWattsValue.stringValue = presentation.inputWatts
        batteryVoltageValue.stringValue = presentation.batteryVoltage
        chargingValue.stringValue = presentation.chargingWatts
        chargingValue.toolTip = "按电池包电压 × 电池电流估算；系统输入功率包含电脑运行消耗。"
        refreshColor()
    }

    /// 采样器可在快照未变化时追加历史点；只更新图表数据，不重复布局电源字段。
    func updateHistory(_ history: [PowerHistorySample]) {
        self.history = history
    }

    /// 缓存由统一采样器推送，拔电和暂无数据时仍允许打开历史浮层。
    func updateBatteryHistory(_ history: [BatteryHistorySample]) {
        batteryHistory = history
    }

    /// 点击输入功率行请求外置图表；图表由上层控制器锚定到主面板左侧。
    private func toggleHistoryChart() {
        guard inputPowerRow.isInteractive else { return }
        onShowPowerHistory?(history, inputPowerRow)
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

/// 统一承载可点击的功率指标行，保留原生文本对齐并提供键盘与辅助功能入口。
@MainActor
private final class PowerMetricRowView: NSView {
    private let labelField: NSTextField
    private let valueField: NSTextField
    var onActivate: (() -> Void)?
    var isInteractive = false { didSet { updateAppearance() } }
    var value: String { get { valueField.stringValue } set { valueField.stringValue = newValue; setAccessibilityValue(newValue) } }
    private var hovering = false { didSet { updateAppearance() } }

    init(label: String) {
        labelField = NSTextField(labelWithString: label)
        valueField = NSTextField(labelWithString: "—")
        super.init(frame: .zero)
        let row = NSStackView(views: [labelField, NSView(), valueField])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = 5
        row.alignment = .firstBaseline
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueField.alignment = .right
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func keyDown(with event: NSEvent) {
        if isInteractive, event.keyCode == 36 || event.keyCode == 49 { onActivate?() } else { super.keyDown(with: event) }
    }

    /// 辅助功能与鼠标、键盘共用同一入口；不可交互的指标不接受按压动作。
    override func accessibilityPerformPress() -> Bool {
        guard isInteractive else { return false }
        onActivate?()
        return true
    }

    private func updateAppearance() {
        wantsLayer = isInteractive
        layer?.backgroundColor = hovering && isInteractive ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
        layer?.cornerRadius = 4
        setAccessibilityRole(isInteractive ? .button : .staticText)
        needsDisplay = true
    }

    @objc private func activate() {
        if isInteractive { onActivate?() }
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
