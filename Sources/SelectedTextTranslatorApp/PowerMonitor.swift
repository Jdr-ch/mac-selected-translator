import AppKit
import IOKit
import IOKit.ps

/// 唯一的电源采集调度器；菜单栏与面板消费同一快照，始终最多一个后台读取任务。
@MainActor
final class PowerMonitor {
    /// IOPM.h 的 kIOPMMessageBatteryStatusHasChanged；Swift 不能导入其宏表达式。
    /// 该私有消息表示 IORegistry 已有新电池数据，不保证所有机型支持，轮询始终保留。
    nonisolated static let batteryStatusChangedMessage: UInt32 = 0xe0024100
    var onChange: ((PowerSnapshot) -> Void)?
    private(set) var snapshot = PowerSnapshot()
    private(set) var sampleCount = 0
    private(set) var interval: TimeInterval?
    private let read: @Sendable () -> PowerSnapshot
    private let queue = DispatchQueue(label: "com.local.selected-text-translator.power", qos: .utility)
    private var timer: Timer?
    private var source: CFRunLoopSource?
    /// 设备通知仅在监控运行且屏幕解锁、系统唤醒时持有；暂停后释放，恢复时重新订阅。
    private var batteryNotificationPort: IONotificationPortRef?
    private var batteryNotification: io_object_t = IO_OBJECT_NULL
    private var observesSystem = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isRunning = false
    private var isReading = false
    private var pendingRefresh = false
    private var generation = 0
    private var panelVisible = false
    private var sleeping = false
    private var locked = false

    /// 表示设备通知订阅成功；失败时仍由原有 IOPS 通知与周期读取更新数据。
    var isObservingBatteryUpdates: Bool { batteryNotification != IO_OBJECT_NULL }

    init(reader: @escaping @Sendable () -> PowerSnapshot = { SystemPowerReader.read() }) {
        read = reader
    }

    /// 生产环境订阅系统通知；测试可只运行同一采集调度，不依赖真实锁屏或电源插拔。
    func start(observeSystem: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        observesSystem = observeSystem
        generation += 1
        if observeSystem {
            source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor [weak monitor] in monitor?.refresh() }
            }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.setSuspended(sleeping: true) }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.setSuspended(sleeping: false) }
            observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.setSuspended(locked: true) }
            observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspended(locked: false) }
        }
        updateBatteryNotifications()
        updateTimer()
        refresh()
    }

    /// 停止后丢弃在途读取的结果；解除通知与计时器，避免退出后继续回调界面。
    func stop() {
        isRunning = false
        observesSystem = false
        generation += 1
        stopBatteryNotifications()
        timer?.invalidate()
        timer = nil
        interval = nil
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        pendingRefresh = false
        isReading = false
    }

    /// 展开时立即读取，收起后仅改变采样节奏，不额外制造一次硬件查询。
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        updateTimer()
        if visible { refresh() }
    }

    /// 锁屏与睡眠独立持有暂停状态，单独解锁不会在仍睡眠时恢复轮询。
    func setSuspended(sleeping: Bool? = nil, locked: Bool? = nil) {
        if let sleeping { self.sleeping = sleeping }
        if let locked { self.locked = locked }
        updateBatteryNotifications()
        updateTimer()
        if !self.sleeping && !self.locked { refresh() }
    }

    /// 只接受电池数据更新消息；沿用同一后台队列和合并机制，暂停或停止后不会查询硬件。
    func batteryServiceDidSend(_ messageType: UInt32) {
        guard messageType == Self.batteryStatusChangedMessage else { return }
        refresh()
    }

    /// 按生命周期订阅 AppleSmartBattery；失败时不重试轮询注册，不影响原有采样兜底。
    private func updateBatteryNotifications() {
        guard isRunning, observesSystem, !sleeping, !locked else {
            stopBatteryNotifications()
            return
        }
        guard batteryNotificationPort == nil else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        var notification: io_object_t = IO_OBJECT_NULL
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, messageType, _ in
            guard messageType == PowerMonitor.batteryStatusChangedMessage, let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak monitor] in monitor?.batteryServiceDidSend(messageType) }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        guard result == KERN_SUCCESS, let notificationSource = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            if notification != IO_OBJECT_NULL { IOObjectRelease(notification) }
            IONotificationPortDestroy(port)
            return
        }
        batteryNotificationPort = port
        batteryNotification = notification
        CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)
    }

    /// 先移除主线程事件源再释放句柄；与注册配对，避免暂停期间新增设备通知唤醒。
    private func stopBatteryNotifications() {
        guard let port = batteryNotificationPort else { return }
        if let notificationSource = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
        }
        if batteryNotification != IO_OBJECT_NULL { IOObjectRelease(batteryNotification) }
        batteryNotification = IO_OBJECT_NULL
        IONotificationPortDestroy(port)
        batteryNotificationPort = nil
    }

    /// 通知和定时请求合并为最多一次待刷新；IOKit 与解析全部在后台队列执行。
    func refresh() {
        guard isRunning, !sleeping, !locked else { return }
        guard !isReading else { pendingRefresh = true; return }
        isReading = true
        let requestedGeneration = generation
        let reader = read
        queue.async { [weak self] in
            let value = autoreleasepool { reader() }
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.generation == requestedGeneration else { return }
                self.isReading = false
                self.sampleCount += 1
                if !self.sleeping && !self.locked {
                    if self.snapshot != value {
                        self.snapshot = value
                        self.onChange?(value)
                    }
                    self.updateTimer()
                }
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
            }
        }
    }

    /// 基础状态由通知及时推动；面板之外降低遥测频率，不宣称传感器按秒刷新。
    static func pollingInterval(panelVisible: Bool, state: PowerState, suspended: Bool) -> TimeInterval? {
        if suspended { return nil }
        if panelVisible { return 1 }
        return state == .charging ? 5 : 15
    }

    /// 周期不变时复用计时器；容差允许系统合并唤醒，菜单跟踪期间仍可更新。
    private func updateTimer() {
        let desired = isRunning ? Self.pollingInterval(panelVisible: panelVisible, state: snapshot.state,
                                                     suspended: sleeping || locked) : nil
        guard desired != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = desired
        guard let desired else { return }
        let timer = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = desired * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 回调统一调回主线程管理调度状态，卸载时按原通知中心注销。
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (PowerMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }
}
