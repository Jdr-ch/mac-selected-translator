import AppKit
import Testing
@testable import GleamApp

/// 确定性历史样例验证充电口径、缺测边界与原生图表，不改动本机电源状态。
@Suite(.serialized)
struct BatteryHistoryTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    /// 连续 1 Hz 刷新仍积累五秒采样点，状态转折不被节流吞掉。
    @Test func frequentReadsRetainHistoryAndImmediateStateTransitions() {
        var history = BatteryHistory()
        for second in 0...15 {
            history.append(snapshot: PowerSnapshot(state: .battery, batteryPercent: 60),
                           at: start.addingTimeInterval(Double(second)))
        }
        #expect(history.samples.map { $0.date.timeIntervalSince(start) } == [0, 5, 10, 15])
        history.append(snapshot: PowerSnapshot(state: .charging, batteryPercent: 60), at: start.addingTimeInterval(16))
        history.append(snapshot: PowerSnapshot(state: .externalPower, batteryPercent: 60), at: start.addingTimeInterval(17))
        history.append(snapshot: PowerSnapshot(state: .battery, batteryPercent: 60), at: start.addingTimeInterval(18))
        #expect(BatteryHistory.chargingIntervals(in: history.samples) == [
            DateInterval(start: start.addingTimeInterval(16), end: start.addingTimeInterval(17))
        ])
        let before = history.samples
        history.append(snapshot: PowerSnapshot(state: .charging), at: start)
        #expect(history.samples == before)
    }

    /// 短暂停和长缺测都切断充电底纹；电量缺失保持空值，恢复后允许继续绘图。
    @Test func suspensionAndMissingTelemetryLeaveGaps() {
        var history = BatteryHistory()
        let charging = PowerSnapshot(state: .charging, batteryPercent: 72)
        history.append(snapshot: charging, at: start)
        history.append(snapshot: charging, at: start.addingTimeInterval(5))
        history.breakContinuity()
        history.append(snapshot: charging, at: start.addingTimeInterval(8))
        history.append(snapshot: charging, at: start.addingTimeInterval(13))
        history.append(snapshot: charging, at: start.addingTimeInterval(100))
        history.append(snapshot: PowerSnapshot(), at: start.addingTimeInterval(101))
        history.append(snapshot: PowerSnapshot(state: .battery, batteryPercent: .nan), at: start.addingTimeInterval(102))
        #expect(history.samples[2].startsNewSegment)
        #expect(history.samples[4].startsNewSegment)
        #expect(history.samples.suffix(2).allSatisfy { $0.percent == nil })
        #expect(BatteryHistory.chargingIntervals(in: history.samples) == [
            DateInterval(start: start, end: start.addingTimeInterval(5)),
            DateInterval(start: start.addingTimeInterval(8), end: start.addingTimeInterval(13)),
            DateInterval(start: start.addingTimeInterval(100), end: start.addingTimeInterval(101))
        ])
    }

    /// 持续运行裁掉两小时前记录；即使通知快速变更状态，内存样本数也有上限。
    @Test func retentionAndCapacityStayBounded() throws {
        var history = BatteryHistory()
        let battery = PowerSnapshot(state: .battery, batteryPercent: 50)
        for second in stride(from: 0, through: 7500, by: 5) {
            history.append(snapshot: battery, at: start.addingTimeInterval(Double(second)))
        }
        #expect(try #require(history.samples.first).date == start.addingTimeInterval(300))
        #expect(history.samples.count == 1441)
        for index in 1...BatteryHistory.maximumSamples {
            let state: PowerState = index.isMultiple(of: 2) ? .charging : .externalPower
            history.append(snapshot: PowerSnapshot(state: state, batteryPercent: 50),
                           at: start.addingTimeInterval(7500 + Double(index) / 10))
        }
        #expect(history.samples.count == BatteryHistory.maximumSamples)
        history.append(snapshot: PowerSnapshot(), at: start.addingTimeInterval(20_000))
        #expect(history.samples.count == 1)
        #expect(history.samples[0].percent == nil)
    }

    /// 无外部功率的电池状态照常推送历史，解锁后即使读数相同也产生带断点的新记录。
    @MainActor
    @Test func monitorPublishesBatteryHistoryWithoutInputPower() async throws {
        let monitor = PowerMonitor(reader: { PowerSnapshot(state: .battery, batteryPercent: 64) })
        var updates: [[BatteryHistorySample]] = []
        monitor.onBatteryHistoryChange = { updates.append($0) }
        defer { monitor.stop() }
        monitor.start(observeSystem: false)
        try await waitForSamples(1, in: monitor)
        #expect(updates.count == 1)
        #expect(monitor.history.samples.isEmpty)
        #expect(updates[0].last?.percent == 64)
        monitor.setSuspended(locked: true)
        monitor.setSuspended(locked: false)
        try await waitForSamples(2, in: monitor)
        #expect(updates.count == 2)
        #expect(updates.last?.last?.startsNewSegment == true)
    }

    /// 两种图表切换后仍使用各自单位；功率摘要统计完整历史，不被绘制抽点改变。
    @Test func sharedChartPreservesMetricUnitsAndFullPowerSummary() {
        let battery = PowerHistoryChartData.battery([
            BatteryHistorySample(date: start, percent: 66, state: .charging),
            BatteryHistorySample(date: start.addingTimeInterval(10), percent: 67, state: .externalPower)
        ])
        #expect(battery.unit == "%")
        #expect(battery.summary.contains("67%"))
        #expect(battery.chargingIntervals == [DateInterval(start: start, duration: 10)])
        let input = PowerHistoryChartData.systemInput((0..<1000).map {
            PowerHistorySample(date: start.addingTimeInterval(Double($0)), watts: $0 == 2 ? 100 : 10)
        })
        #expect(input.unit == " W")
        #expect(input.points.count == 240)
        #expect(input.summary == "当前 10.0 W · 最高 100.0 W · 平均 10.1 W")
        #expect(input.chargingIntervals.isEmpty)
    }

    /// 状态行在充电、接电未充电、拔电和未知态均可打开已缓存历史。
    @MainActor
    @Test func batteryEntryRemainsAvailableAcrossPowerStates() throws {
        let info = PowerInfoView(showPower: true)
        let history = [BatteryHistorySample(date: start, percent: 80, state: .charging)]
        info.updateBatteryHistory(history)
        var received: [[BatteryHistorySample]] = []
        info.onShowBatteryHistory = { samples, _ in received.append(samples) }
        for state in [PowerState.charging, .externalPower, .battery, .unavailable] {
            let snapshot = PowerSnapshot(state: state, batteryPercent: 80)
            info.update(snapshot: snapshot, presentation: PowerPresentation(snapshot: snapshot, showPower: true))
            let row = try #require(descendants(info).first { $0.accessibilityLabel() == "电池状态" })
            #expect(!row.isHidden)
            #expect(row.accessibilityValue() as? String == state.title)
            #expect(row.accessibilityPerformPress())
        }
        #expect(received == Array(repeating: history, count: 4))
    }

    /// 离屏渲染检查布局和图形：两段充电之间含接电暂停，末段含未记录空档。
    @MainActor
    @Test func chartRendersChargingPeriodsAndHover() throws {
        let samples = (0...120).compactMap { index -> BatteryHistorySample? in
            if (81..<100).contains(index) { return nil }
            let state: PowerState = index < 30 || (50..<80).contains(index) ? .charging : .externalPower
            return BatteryHistorySample(date: start.addingTimeInterval(Double(index) * 15),
                                        percent: 45 + Double(min(index, 80)) / 2, state: state)
        }
        let controller = PowerHistoryChartController()
        controller.update(.battery(samples))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 246),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // NSWindow 安装控制器时采用内容固有宽度；再应用生产浮层的实际尺寸。
        window.setContentSize(NSSize(width: 320, height: 246))
        defer { window.close() }
        let chart = try #require(descendants(controller.view).compactMap { $0 as? PowerHistoryChartView }.first)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.view.layoutSubtreeIfNeeded()
            #expect(chart.bounds.size == NSSize(width: 292, height: 160))
            #expect(chart.data.chargingIntervals.count == 2)
            try export(controller.view, name: "battery-history-\(dark ? "dark" : "light")")
        }
        let location = chart.convert(NSPoint(x: 70, y: 75), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        chart.mouseMoved(with: event)
        try export(controller.view, name: "battery-history-hover")
        controller.update(.battery([]))
        try export(controller.view, name: "battery-history-empty")
    }

    /// 只等待注入读取器完成，不等待真实电池轮询或触发系统通知。
    @MainActor
    private func waitForSamples(_ count: Int, in monitor: PowerMonitor) async throws {
        for _ in 0..<50 {
            if monitor.sampleCount >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(monitor.sampleCount >= count)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// 仅在指定目录导出测试样例，不把离屏图像作为真实鼠标验收证据。
    @MainActor
    private func export(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["POWER_MONITOR_RENDER_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: destination.appendingPathComponent("\(name).png"))
    }
}
