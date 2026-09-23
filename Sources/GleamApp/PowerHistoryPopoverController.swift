import AppKit

/// 两种历史共用一个浮层；锚定当前指标行，切换指标时重新定位而不叠加窗口。
@MainActor
final class PowerHistoryPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let chartController: PowerHistoryChartController

    var isShown: Bool { popover.isShown }
    private(set) var metric: PowerHistoryMetric?

    override init() {
        chartController = PowerHistoryChartController()
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = chartController
        popover.contentSize = NSSize(width: 320, height: 224)
        popover.delegate = self
    }

    /// 再次点击同一指标收起；切换指标则使用对应单位、历史与锚点展开。
    func toggle(relativeTo anchor: NSView, data: PowerHistoryChartData) {
        if isShown, metric == data.metric { close(); return }
        if isShown { close() }
        metric = data.metric
        chartController.update(data)
        popover.contentSize = NSSize(width: 320, height: data.metric == .battery ? 246 : 224)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }

    /// 只刷新当前可见指标，后台的另一条历史不会抢占图表内容。
    func update(_ data: PowerHistoryChartData) {
        guard isShown, metric == data.metric else { return }
        chartController.update(data)
    }

    func close() {
        popover.performClose(nil)
    }
}

/// 标题、摘要和折线使用同一份展示数据，电池图补充记录空档的解释。
@MainActor
final class PowerHistoryChartController: NSViewController {
    private let chart = PowerHistoryChartView()
    private let titleLabel = NSTextField(labelWithString: "最近两小时系统输入功率")
    private let summaryLabel = NSTextField(labelWithString: "暂无最近两小时数据")
    private let noteLabel = NSTextField(labelWithString: "空档表示未记录；重启后重新记录")

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
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true
        stack.addArrangedSubview(noteLabel)
        view = root
    }

    /// 首次展开也先完成视图加载，防止 loadView 覆盖记录说明的显隐状态。
    func update(_ data: PowerHistoryChartData) {
        _ = view
        chart.data = data
        titleLabel.stringValue = data.title
        summaryLabel.stringValue = data.summary
        noteLabel.isHidden = data.metric != .battery
        chart.setAccessibilityLabel(data.title + "；" + data.summary)
    }
}

/// 轻量 AppKit 折线图；鼠标移动时吸附最近采样点并绘制时间和值提示。
@MainActor
final class PowerHistoryChartView: NSView {
    var data = PowerHistoryChartData.systemInput([]) { didSet { hoveredIndex = nil; needsDisplay = true } }
    /// 悬停索引只对应当前数据；离开或收到新历史时清空，避免读到旧位置的状态。
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plot = plotBounds
        guard plot.contains(point), let first = data.points.first, let last = data.points.last else {
            hoveredIndex = nil; needsDisplay = true; return
        }
        let ratio = min(1, max(0, (point.x - plot.minX) / plot.width))
        let date = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) * Double(ratio))
        // 时间轴按真实间隔绘制；长缺测区不把远处的充电状态吸附过来。
        hoveredIndex = data.points.indices.min {
            abs(data.points[$0].date.timeIntervalSince(date)) < abs(data.points[$1].date.timeIntervalSince(date))
        }
        if data.metric == .battery, let index = hoveredIndex,
           abs(data.points[index].date.timeIntervalSince(date)) > BatteryHistory.maximumGap {
            hoveredIndex = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let plot = plotBounds
        guard !data.points.isEmpty else {
            drawLabel("暂无最近两小时数据", at: CGPoint(x: bounds.midX - 42, y: bounds.midY - 5))
            return
        }
        let values = data.points.compactMap(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let padding = max(1, (maxValue - minValue) * 0.12)
        let lower = data.metric == .battery ? 0 : max(0, minValue - padding)
        let upper = data.metric == .battery ? 100 : max(lower + 1, maxValue + padding)
        // 底纹仅由充电状态区间生成，接电未充电与无记录间隔均不着色。
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        for interval in data.chargingIntervals {
            let startX = x(for: interval.start, plot: plot)
            let endX = x(for: interval.end, plot: plot)
            NSBezierPath(rect: NSRect(x: startX, y: plot.minY, width: endX - startX, height: plot.height)).fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for index in 0...2 {
            let y = plot.minY + plot.height * CGFloat(index) / 2
            let grid = NSBezierPath(); grid.move(to: CGPoint(x: plot.minX, y: y)); grid.line(to: CGPoint(x: plot.maxX, y: y)); grid.stroke()
        }
        drawLabel(String(format: "%.0f", upper) + data.unit, at: CGPoint(x: 4, y: plot.minY - 2))
        drawLabel(String(format: "%.0f", lower) + data.unit, at: CGPoint(x: 4, y: plot.maxY - 10))
        let path = NSBezierPath()
        var previous: PowerHistoryChartPoint?
        for sample in data.points {
            guard let point = point(for: sample, plot: plot, lower: lower, upper: upper) else {
                previous = nil
                continue
            }
            let followsGap = data.metric == .battery && previous.map {
                sample.date.timeIntervalSince($0.date) > BatteryHistory.maximumGap
            } == true
            if previous == nil || sample.startsNewSegment || followsGap {
                path.move(to: point)
                // 单点区段也需要可见，不用连线跨过锁屏、休眠或缺失电量。
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
            } else {
                path.line(to: point)
            }
            previous = sample
        }
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.8; path.stroke()
        if let hoveredIndex {
            let sample = data.points[hoveredIndex]
            let point = point(for: sample, plot: plot, lower: lower, upper: upper)
                ?? CGPoint(x: x(for: sample.date, plot: plot), y: plot.midY)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            let guide = NSBezierPath(); guide.move(to: CGPoint(x: point.x, y: plot.minY)); guide.line(to: CGPoint(x: point.x, y: plot.maxY)); guide.stroke()
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            drawTooltip(for: sample, near: point)
        } else if let last = data.points.last, let point = point(for: last, plot: plot, lower: lower, upper: upper) {
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
        if values.isEmpty {
            drawLabel("电量暂不可用", at: CGPoint(x: plot.midX - 30, y: plot.midY - 5))
        }
        drawLabel(timeLabel(data.points.first?.date), at: CGPoint(x: plot.minX, y: bounds.maxY - 14))
        drawLabel(timeLabel(data.points.last?.date), at: CGPoint(x: plot.maxX - 30, y: bounds.maxY - 14))
    }

    private var plotBounds: CGRect { bounds.insetBy(dx: 34, dy: 24) }

    /// 真实时间决定横坐标；单个采样点居中，长缺测间隔保留原有宽度。
    private func x(for date: Date, plot: CGRect) -> CGFloat {
        guard let first = data.points.first, let last = data.points.last, last.date > first.date else { return plot.midX }
        return plot.minX + plot.width * CGFloat(date.timeIntervalSince(first.date) / last.date.timeIntervalSince(first.date))
    }

    /// 缺失电量不产生纵坐标，让调用方断开路径而不是画到 0%。
    private func point(for sample: PowerHistoryChartPoint, plot: CGRect, lower: Double, upper: Double) -> CGPoint? {
        guard let value = sample.value else { return nil }
        let y = plot.maxY - plot.height * CGFloat((value - lower) / (upper - lower))
        return CGPoint(x: x(for: sample.date, plot: plot), y: y)
    }

    /// 电池提示同时给出采样时间、电量和供电状态，避免把接电误读为正在充电。
    private func drawTooltip(for sample: PowerHistoryChartPoint, near point: CGPoint) {
        let value = sample.value.map { String(format: data.metric == .battery ? "%.0f" : "%.1f", $0) + data.unit } ?? "—"
        var text = "\(timeLabel(sample.date, includeSeconds: true))  \(value)"
        if let state = sample.state { text += "\n" + state.title }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        var rect = NSRect(x: point.x + 8, y: point.y - size.height - 12, width: size.width + 12, height: size.height + 8)
        if rect.maxX > bounds.maxX - 4 { rect.origin.x = point.x - rect.width - 8 }
        if rect.minY < 4 { rect.origin.y = point.y + 8 }
        rect.origin.x = max(4, min(rect.origin.x, bounds.maxX - rect.width - 4))
        rect.origin.y = max(4, min(rect.origin.y, bounds.maxY - rect.height - 4))
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
    }

    /// 坐标轴精确到分钟，悬停精确到秒以区分快速充电状态变化。
    private func timeLabel(_ date: Date?, includeSeconds: Bool = false) -> String {
        guard let date else { return "—" }
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        if includeSeconds {
            return String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        }
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
