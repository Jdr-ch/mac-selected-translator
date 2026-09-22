import AppKit

/// 独立承载功率历史的浮层；锚定指标行并从主电源面板左侧展开，避免挤压双栏布局。
@MainActor
final class PowerHistoryPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let chartController: PowerHistoryChartController

    var isShown: Bool { popover.isShown }

    override init() {
        chartController = PowerHistoryChartController()
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = chartController
        popover.contentSize = NSSize(width: 320, height: 205)
        popover.delegate = self
    }

    /// 再次点击同一行关闭浮层；首次点击从指标行左侧展示当前历史快照。
    func toggle(relativeTo anchor: NSView, samples: [PowerHistorySample]) {
        if isShown { close(); return }
        chartController.update(samples)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }

    func update(_ samples: [PowerHistorySample]) {
        chartController.update(samples)
    }

    func close() {
        popover.performClose(nil)
    }
}

@MainActor
private final class PowerHistoryChartController: NSViewController {
    private let chart = PowerHistoryChartView()
    private let titleLabel = NSTextField(labelWithString: "最近两小时系统输入功率")
    private let summaryLabel = NSTextField(labelWithString: "暂无最近两小时数据")

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(summaryLabel)
        stack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 160).isActive = true
        view = root
    }

    func update(_ samples: [PowerHistorySample]) {
        chart.samples = samples
        let values = samples.map(\.watts)
        guard let latest = values.last else {
            summaryLabel.stringValue = "暂无最近两小时数据"
            return
        }
        let maximum = values.max() ?? latest
        let average = values.reduce(0, +) / Double(values.count)
        summaryLabel.stringValue = String(format: "当前 %.1f W · 最高 %.1f W · 平均 %.1f W", latest, maximum, average)
    }
}

/// 轻量 AppKit 折线图；鼠标移动时吸附最近采样点并绘制时间和值提示。
@MainActor
private final class PowerHistoryChartView: NSView {
    var samples: [PowerHistorySample] = [] { didSet { hoveredIndex = nil; needsDisplay = true } }
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plot = plotBounds
        guard plot.contains(point), !displaySamples.isEmpty else { hoveredIndex = nil; needsDisplay = true; return }
        let ratio = min(1, max(0, (point.x - plot.minX) / plot.width))
        hoveredIndex = Int((ratio * CGFloat(displaySamples.count - 1)).rounded())
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let plot = plotBounds
        guard !displaySamples.isEmpty else {
            drawLabel("暂无最近两小时数据", at: CGPoint(x: bounds.midX - 42, y: bounds.midY - 5))
            return
        }
        let values = displaySamples.map(\.watts)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let padding = max(1, (maxValue - minValue) * 0.12)
        let lower = max(0, minValue - padding)
        let upper = max(lower + 1, maxValue + padding)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for index in 0...2 {
            let y = plot.minY + plot.height * CGFloat(index) / 2
            let grid = NSBezierPath(); grid.move(to: CGPoint(x: plot.minX, y: y)); grid.line(to: CGPoint(x: plot.maxX, y: y)); grid.stroke()
        }
        drawLabel(String(format: "%.0f W", upper), at: CGPoint(x: 4, y: plot.minY - 2))
        drawLabel(String(format: "%.0f W", lower), at: CGPoint(x: 4, y: plot.maxY - 10))
        let path = NSBezierPath()
        for (index, sample) in displaySamples.enumerated() {
            let point = point(for: index, sample: sample, plot: plot, lower: lower, upper: upper)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.8; path.stroke()
        if let hoveredIndex {
            let point = point(for: hoveredIndex, sample: displaySamples[hoveredIndex], plot: plot, lower: lower, upper: upper)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            let guide = NSBezierPath(); guide.move(to: CGPoint(x: point.x, y: plot.minY)); guide.line(to: CGPoint(x: point.x, y: plot.maxY)); guide.stroke()
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            drawTooltip(for: displaySamples[hoveredIndex], near: point)
        } else {
            let last = displaySamples[displaySamples.count - 1]
            let point = point(for: displaySamples.count - 1, sample: last, plot: plot, lower: lower, upper: upper)
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
        drawLabel(timeLabel(displaySamples.first?.date), at: CGPoint(x: plot.minX, y: bounds.maxY - 14))
        drawLabel(timeLabel(displaySamples.last?.date), at: CGPoint(x: plot.maxX - 30, y: bounds.maxY - 14))
    }

    private var plotBounds: CGRect { bounds.insetBy(dx: 34, dy: 24) }
    private var displaySamples: [PowerHistorySample] {
        guard samples.count > 240 else { return samples }
        let stride = Double(samples.count - 1) / 239
        return (0..<240).map { samples[Int((Double($0) * stride).rounded())] }
    }

    private func point(for index: Int, sample: PowerHistorySample, plot: CGRect, lower: Double, upper: Double) -> CGPoint {
        let x = plot.minX + plot.width * CGFloat(index) / CGFloat(max(1, displaySamples.count - 1))
        let y = plot.maxY - plot.height * CGFloat((sample.watts - lower) / (upper - lower))
        return CGPoint(x: x, y: y)
    }

    private func drawTooltip(for sample: PowerHistorySample, near point: CGPoint) {
        let formattedWatts = String(format: "%.1f W", sample.watts)
        let text = "\(timeLabel(sample.date))  \(formattedWatts)"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        var rect = NSRect(x: point.x + 8, y: point.y - size.height - 12, width: size.width + 12, height: size.height + 8)
        if rect.maxX > bounds.maxX - 4 { rect.origin.x = point.x - rect.width - 8 }
        if rect.minY < 4 { rect.origin.y = point.y + 8 }
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
