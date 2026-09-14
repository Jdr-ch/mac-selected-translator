import AppKit
import Testing
import os
@testable import SelectedTextTranslatorApp

/// 电源字段、采集生命周期和原生面板的聚焦验收；不更改本机电源或休眠策略。
@Suite(.serialized)
@MainActor
struct PowerMonitorTests {
    /// 固定样例仅验证单位与来源：68.2W 整机输入不能当作 25.4W 电池充电功率。
    static var registry: [String: Any] {
        ["ExternalConnected": true, "IsCharging": true, "CurrentCapacity": 68,
         "Voltage": 12200, "Amperage": 2080,
         "AdapterDetails": ["Name": "Apple 140W USB-C Power Adapter", "Watts": 140,
                            "AdapterVoltage": 28000, "Current": 4990],
         "PowerTelemetryData": ["SystemVoltageIn": 27720, "SystemPowerIn": 68200]]
    }

    @Test func separatesAdapterInputAndBatteryCharging() throws {
        let snapshot = PowerSnapshot.decode(registry: Self.registry, source: [:])
        #expect(snapshot.state == .charging)
        #expect(snapshot.adapterCurrent == 4.99)
        #expect(snapshot.inputWatts == 68.2)
        #expect(snapshot.batteryCurrent == 2.08)
        #expect(abs(try #require(snapshot.estimatedChargingWatts) - 25.376) < 0.001)
        let presentation = PowerPresentation(snapshot: snapshot, showPower: true)
        #expect(presentation.menuValue == "≈25.4 W")
        #expect(presentation.menuPowerDescription == "电池充电功率 ≈25.4 W")
    }

    /// 接电暂停充电显示整机输入；拔电后隐藏数字，并清除驱动缓存的适配器数据。
    @Test func externalIdleShowsInputAndUnplugClearsCachedAdapter() {
        var raw = Self.registry
        raw["IsCharging"] = false
        raw["Amperage"] = 0
        let idle = PowerSnapshot.decode(registry: raw, source: [:])
        #expect(idle.state == .externalPower)
        let presentation = PowerPresentation(snapshot: idle, showPower: true)
        #expect(presentation.menuValue == "68.2 W")
        #expect(presentation.menuPowerDescription == "系统输入功率 68.2 W")
        #expect(idle.inputWatts == 68.2)
        raw["ExternalConnected"] = false
        let unplugged = PowerSnapshot.decode(registry: raw, source: [:])
        #expect(unplugged.state == .battery)
        #expect(unplugged.adapterName == nil)
        #expect(unplugged.inputWatts == nil)
        #expect(unplugged.batteryVoltage == 12.2)
        let unpluggedPresentation = PowerPresentation(snapshot: unplugged, showPower: true)
        #expect(unpluggedPresentation.showBattery)
        #expect(unpluggedPresentation.menuValue.isEmpty)
        #expect(unpluggedPresentation.menuPowerDescription == nil)
    }

    /// 新开关默认开启，旧电流选择不参与迁移；关闭与重新开启都能从独立偏好域回读。
    @Test func powerPreferenceDefaultsOnAndPersistsExplicitChoice() throws {
        let suiteName = "PowerMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(PowerDisplayPreference.isPowerShown(in: defaults))
        defaults.set("amperes", forKey: "powerMonitor.displayMetric")
        #expect(PowerDisplayPreference.isPowerShown(in: defaults))
        for showPower in [false, true] {
            defaults.set(showPower, forKey: PowerDisplayPreference.defaultsKey)
            let reloaded = try #require(UserDefaults(suiteName: suiteName))
            #expect(PowerDisplayPreference.isPowerShown(in: reloaded) == showPower)
        }
    }

    /// 关闭仅隐藏菜单数字；面板读数仍可见，电池与未知状态即使带有旧输入值也不展示。
    @Test func hiddenPowerPreservesPanelReadingsAcrossStates() {
        for state in [PowerState.charging, .externalPower, .battery, .unavailable] {
            var snapshot = PowerSnapshot.decode(registry: Self.registry, source: [:])
            snapshot.state = state
            let hidden = PowerPresentation(snapshot: snapshot, showPower: false)
            #expect(hidden.menuValue.isEmpty)
            #expect(hidden.menuPowerDescription == nil)
            #expect(hidden.inputWatts == "68.2 W")
            if state == .battery || state == .unavailable {
                #expect(PowerPresentation(snapshot: snapshot, showPower: true).menuValue.isEmpty)
            }
        }
    }

    @Test func signedDischargeAndMissingDataNeverBecomeChargingPower() {
        #expect(PowerSnapshot.signedMilliamps(NSNumber(value: UInt32(bitPattern: -2000))) == -2000)
        #expect(PowerSnapshot.signedMilliamps(NSNumber(value: UInt64(bitPattern: -2000))) == -2000)
        var raw = Self.registry
        raw["Amperage"] = -2000
        #expect(PowerSnapshot.decode(registry: raw, source: [:]).estimatedChargingWatts == nil)
        raw["Voltage"] = Double.nan
        raw["Amperage"] = true
        let invalid = PowerSnapshot.decode(registry: raw, source: [:])
        #expect(invalid.batteryCurrent == nil)
        #expect(invalid.batteryVoltage == nil)
        #expect(PowerPresentation(snapshot: invalid, showPower: true).menuValue == "—")
        #expect(PowerSnapshot.decode(registry: [:], source: [:]).state == .unavailable)
    }

    @Test func publicSourceSupportsBasicStateWithoutPrivateTelemetry() {
        let snapshot = PowerSnapshot.decode(registry: [:], source: [
            "Power Source State": "AC Power", "Is Charging": false,
            "Current Capacity": 95, "Max Capacity": 100
        ])
        #expect(snapshot.state == .externalPower)
        #expect(snapshot.batteryPercent == 95)
        #expect(snapshot.inputWatts == nil)
        #expect(PowerPresentation(snapshot: snapshot, showPower: true).menuValue == "—")
        var zeroInput = snapshot
        zeroInput.inputWatts = 0
        #expect(PowerPresentation(snapshot: zeroInput, showPower: true).menuValue == "0.0 W")
    }

    /// 合并通知风暴，并检验锁屏/睡眠交错及停止后不会重新创建周期任务。
    @Test func samplingCoalescesAndPausesAcrossLifecycle() async throws {
        let fixture = PowerSnapshot.decode(registry: Self.registry, source: [:])
        let monitor = PowerMonitor(reader: { Thread.sleep(forTimeInterval: 0.025); return fixture })
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        monitor.start(observeSystem: false)
        for _ in 0..<30 { monitor.refresh() }
        try await Task.sleep(for: .milliseconds(180))
        #expect(monitor.sampleCount == 2)
        #expect(changes == 1)
        #expect(monitor.interval == 5)
        monitor.setPanelVisible(true)
        #expect(monitor.interval == 1)
        monitor.setSuspended(sleeping: true, locked: true)
        #expect(monitor.interval == nil)
        monitor.setSuspended(sleeping: false)
        #expect(monitor.interval == nil)
        monitor.setSuspended(locked: false)
        #expect(monitor.interval == 1)
        monitor.setPanelVisible(false)
        #expect(monitor.interval == 5)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.interval == nil)
        #expect(changes == 1)
        #expect(PowerMonitor.pollingInterval(panelVisible: false, state: .battery, suspended: false) == 15)
        #expect(PowerMonitor.pollingInterval(panelVisible: false, state: .externalPower, suspended: false) == 15)
    }

    /// 模拟实测设备消息，验证新功率不必等 15 秒，并且消息风暴、无关消息与暂停都沿用原调度。
    @Test func batteryNotificationRefreshesInputWithoutWaitingForTimer() async throws {
        let reading = OSAllocatedUnfairLock(initialState: PowerSnapshot(state: .externalPower, inputWatts: 44.9))
        let monitor = PowerMonitor(reader: {
            Thread.sleep(forTimeInterval: 0.025)
            return reading.withLock { $0 }
        })
        defer { monitor.stop() }
        monitor.start(observeSystem: false)
        try await waitForSamples(1, in: monitor)
        #expect(monitor.interval == 15)
        #expect(!monitor.isObservingBatteryUpdates)
        monitor.batteryServiceDidSend(0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.sampleCount == 1)
        reading.withLock { $0.inputWatts = 85.5 }
        for _ in 0..<20 { monitor.batteryServiceDidSend(0xe0024100) }
        try await waitForSamples(3, in: monitor)
        #expect(monitor.sampleCount == 3)
        #expect(monitor.snapshot.inputWatts == 85.5)
        #expect(monitor.interval == 15)
        monitor.setSuspended(locked: true)
        monitor.batteryServiceDidSend(0xe0024100)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.sampleCount == 3)
        monitor.setSuspended(locked: false)
        try await waitForSamples(4, in: monitor)
        monitor.stop()
        monitor.batteryServiceDidSend(0xe0024100)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.sampleCount == 4)
        #expect(monitor.interval == nil)
    }

    /// 有界等待后台读取完成；一秒内必须得到新样本，避免误把下一次 15 秒轮询当成通知生效。
    private func waitForSamples(_ count: Int, in monitor: PowerMonitor) async throws {
        for _ in 0..<100 {
            if monitor.sampleCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor.sampleCount >= count)
    }

    /// 标题缓存不改变动画图片大小，也不新增拦截点击的子视图。
    @Test func staticPrefixCachesAndKeepsNativeImageGeometry() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        let subviews = button.subviews
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: 22)
        button.image = animator.image(at: 0, isDark: false, reduceMotion: true)
        let display = PowerStatusDisplay()
        let snapshot = PowerSnapshot.decode(registry: Self.registry, source: [:])
        let presentation = PowerPresentation(snapshot: snapshot, showPower: true)
        for _ in 0..<90 { display.update(presentation, button: button) }
        #expect(display.renderCount == 1)
        #expect(button.image?.size == CGSize(width: 44, height: 22))
        #expect(button.subviews == subviews)
        #expect(button.attributedTitle.length == 1)
        button.setFrameSize(NSSize(width: try #require(button.cell).cellSize.width, height: 24))
        let bounds = button.bounds
        let imageFrame = try #require(button.cell).imageRect(forBounds: bounds)
        #expect(imageFrame.width == 44 && imageFrame.minX > 60)
        let indicatorPoint = CGPoint(x: imageFrame.midX - 13, y: imageFrame.midY)
        #expect(StatusItemVisualStyle.hitTarget(at: indicatorPoint, buttonBounds: bounds,
            imageFrame: imageFrame, isPreventingSleep: true) == .sleepIndicator)
        #expect(StatusItemVisualStyle.hitTarget(at: CGPoint(x: 35, y: 12), buttonBounds: bounds,
            imageFrame: imageFrame, isPreventingSleep: true) == .menu)
        #expect(StatusItemVisualStyle.hitTarget(at: indicatorPoint, buttonBounds: bounds,
            imageFrame: imageFrame, isPreventingSleep: false) == .menu)
        // 功率保留一位小数后相同则命中缓存；隐藏数字后，任意功率读数变化也不应重绘前缀。
        var sample = snapshot
        sample.state = .externalPower
        display.update(PowerPresentation(snapshot: sample, showPower: true), button: button)
        let inputRenderCount = display.renderCount
        sample.inputWatts = 68.21
        display.update(PowerPresentation(snapshot: sample, showPower: true), button: button)
        #expect(display.renderCount == inputRenderCount)
        sample.inputWatts = 70
        display.update(PowerPresentation(snapshot: sample, showPower: true), button: button)
        #expect(display.renderCount == inputRenderCount + 1)
        display.update(PowerPresentation(snapshot: sample, showPower: false), button: button)
        let hiddenRenderCount = display.renderCount
        for watts in [0.0, 35.7, 140.0] {
            sample.inputWatts = watts
            display.update(PowerPresentation(snapshot: sample, showPower: false), button: button)
        }
        #expect(display.renderCount == hiddenRenderCount)
        for dark in [false, true] {
            button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for state in [PowerState.charging, .externalPower, .battery] {
                var sample = snapshot
                sample.state = state
                display.update(PowerPresentation(snapshot: sample, showPower: true), button: button)
                animator.isPreventingSleep = true
                button.image = animator.image(at: 0, isDark: dark, reduceMotion: true)
                button.setFrameSize(NSSize(width: try #require(button.cell).cellSize.width, height: 24))
                try export(button, name: "status-\(state.rawValue)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// 原生菜单栏先完成自身排版，再检查实际像素；避免手动设为 24pt 掩盖基线错位。
    @Test func powerBadgeCentersInNativeAndResizedStatusButton() async throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: NSStatusBar.system.thickness)
        let display = PowerStatusDisplay()
        button.imageScaling = .scaleNone
        button.image = animator.image(at: 0, isDark: false, reduceMotion: true)
        for state in [PowerState.externalPower, .charging, .battery] {
            var snapshot = PowerSnapshot.decode(registry: Self.registry, source: [:])
            snapshot.state = state
            display.update(PowerPresentation(snapshot: snapshot, showPower: true), button: button)
            try await Task.sleep(for: .milliseconds(40))
            try verifyBadgeCenter(in: button, state: state)
            // 系统会把 NSStatusBarButton 高度恢复为菜单栏高度，其他尺寸用原生 NSButton 承载同一附件。
            for height: CGFloat in [22, 24, 32, 39] {
                let sample = NSButton(frame: NSRect(x: 0, y: 0, width: button.bounds.width, height: height))
                sample.isBordered = false
                sample.imageScaling = .scaleNone
                sample.imagePosition = .imageRight
                sample.image = button.image
                sample.attributedTitle = button.attributedTitle
                try verifyBadgeCenter(in: sample, state: state)
            }
        }
    }

    /// 以绘制后真实 bounds 为准，比较有色像素的中心和完整高度。
    private func verifyBadgeCenter(in button: NSButton, state: PowerState) throws {
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let height = button.bounds.height
        let scale = CGFloat(bitmap.pixelsHigh) / height
        let imageFrame = try #require(button.cell).imageRect(forBounds: button.bounds)
        let colored = try #require(badgeBounds(in: bitmap, beforeX: Int(imageFrame.minX * scale), state: state))
        #expect(abs(colored.midY / scale - height / 2) <= 1)
        #expect(colored.height / scale >= 17)
    }

    /// 从真实位图提取前缀中的状态色，检查整块图形的高度与中心，不用布局公式替代绘制验收。
    private func badgeBounds(in bitmap: NSBitmapImageRep, beforeX: Int, state: PowerState) -> CGRect? {
        var pixels: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<min(beforeX, bitmap.pixelsWide) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let matches: Bool
                switch state {
                case .charging: matches = g > r + 0.12 && g > b + 0.08
                case .externalPower: matches = r > b + 0.15 && g > b + 0.08
                case .battery: matches = b > r + 0.15 && b > g + 0.08
                case .unavailable: matches = false
                }
                if matches { pixels.append(CGPoint(x: x, y: y)) }
            }
        }
        guard let minX = pixels.map(\.x).min(), let maxX = pixels.map(\.x).max(),
              let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 验证实际 AppKit 布局与原命令投递；指定输出目录时导出三态原生面板用于视觉检查。
    @Test func nativePanelPreservesCommandsAndRendersStates() async throws {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let receiver = PowerCommandReceiver()
        let titles = ["翻译当前选中文字", "整理", "对齐", "禁止休眠", "iPhone 定位", "生成流程图", "内容润色",
                      "测试弹窗", "查看快捷键状态", "检查辅助功能权限", "模型切换：GPT...", "退出"]
        for (index, title) in titles.enumerated() {
            if [1, 4, 7, 11].contains(index) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(PowerCommandReceiver.receive(_:)), keyEquivalent: "")
            item.target = receiver
            menu.addItem(item)
        }
        let popover = PowerPopoverController(menu: menu, showPower: true)
        let controller = popover.content
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 490, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 490, height: 450))
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let checkbox = try #require(descendants(controller.info).compactMap { $0 as? NSButton }.first)
        #expect(checkbox.title == "功率")
        #expect(checkbox.state == .on)
        #expect(checkbox.accessibilityLabel() == "菜单栏显示功率")
        var selections: [Bool] = []
        popover.onShowPowerChange = { selections.append($0) }
        checkbox.performClick(nil)
        #expect(checkbox.state == .off)
        checkbox.performClick(nil)
        #expect(checkbox.state == .on)
        #expect(selections == [false, true])
        let restored = PowerInfoView(showPower: false)
        #expect(descendants(restored).compactMap { $0 as? NSButton }.first?.state == .off)
        #expect(descendants(controller.info).allSatisfy { !($0 is NSPopUpButton) })
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }.filter { $0 !== checkbox }
        #expect(buttons.count == titles.count)
        try #require(buttons.first).performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(receiver.lastTitle == titles.first)
        for state in [PowerState.charging, .externalPower, .battery] {
            var raw = Self.registry
            raw["IsCharging"] = state == .charging
            raw["ExternalConnected"] = state != .battery
            let snapshot = PowerSnapshot.decode(registry: raw, source: [:])
            controller.info.update(snapshot: snapshot, presentation: PowerPresentation(snapshot: snapshot, showPower: true))
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.info.frame.width == 220)
            #expect(buttons.allSatisfy { $0.frame.width > 200 && $0.alignmentRect(forFrame: $0.frame).height == 29 },
                    "命令区域尺寸：\(buttons.map { $0.frame })")
            #expect(controller.view.bounds.size == CGSize(width: 490, height: 450))
            try export(controller.view, name: "power-\(state.rawValue)")
        }
        controller.setViewportHeight(340)
        window.setContentSize(NSSize(width: 490, height: 340))
        controller.view.layoutSubtreeIfNeeded()
        controller.focusCommand(at: titles.count - 1)
        let lastButton = try #require(buttons.last)
        #expect(lastButton.visibleRect.height == lastButton.bounds.height)
        checkbox.scrollToVisible(checkbox.bounds)
        #expect(checkbox.visibleRect.contains(checkbox.bounds))
        try export(controller.view, name: "power-compact")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// 只导出原生视图的位图，不把离屏快照当作真实鼠标或双屏验收。
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

/// 记录原 NSMenuItem 经过 NSApp.sendAction 后的实际目标投递。
@MainActor
private final class PowerCommandReceiver: NSObject {
    var lastTitle: String?
    @objc func receive(_ sender: NSMenuItem) { lastTitle = sender.title }
}
