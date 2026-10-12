import Foundation

/// Owns the sleep assertion and one-shot restoration; menu-bar feedback updates only on state changes.
final class SleepPreventionController: NSObject {
    /// Notifies the owner when the sleep assertion changes so all visible state stays synchronized.
    var onStateChange: (() -> Void)?

    /// A non-nil activity means both system and display idle sleep are currently blocked.
    private var sleepPreventionActivity: NSObjectProtocol?
    private var automaticSleepRestorationTimer: Timer?
    private let screenLockNotificationCenter: NotificationCenter

    init(screenLockNotificationCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        self.screenLockNotificationCenter = screenLockNotificationCenter
        super.init()
        screenLockNotificationCenter.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    deinit {
        screenLockNotificationCenter.removeObserver(self)
    }

    /// Drives both the menu action and the sleep indicator from the process activity source of truth.
    var isPreventingSleep: Bool {
        sleepPreventionActivity != nil
    }

    /// Returns the next action shown in the menu for the current sleep state.
    var actionTitle: String {
        Self.actionTitle(isPreventingSleep: isPreventingSleep)
    }

    /// Keeps the historical menu wording: the item changes from enabling to restoring sleep.
    static func actionTitle(isPreventingSleep: Bool) -> String {
        isPreventingSleep ? "保持休眠" : "禁止休眠"
    }

    static func automaticSleepRestorationDate(
        enabledAt: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let cutoff = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: enabledAt),
              enabledAt < cutoff else {
            return nil
        }
        return cutoff
    }

    /// Switches between allowing normal idle sleep and preventing both idle sleep modes.
    func toggle() {
        if sleepPreventionActivity == nil {
            preventSystemSleep()
        } else {
            restoreSystemSleep()
        }
    }

    /// Releases the sleep assertion and cancels scheduled restoration during termination or menu toggle.
    func restoreSystemSleep() {
        automaticSleepRestorationTimer?.invalidate()
        automaticSleepRestorationTimer = nil
        if let sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(sleepPreventionActivity)
            self.sleepPreventionActivity = nil
        }
        onStateChange?()
    }

    @objc private func screenDidLock(_ notification: Notification) {
        guard isPreventingSleep else {
            return
        }
        restoreSystemSleep()
    }

    /// Starts one process assertion covering both computer and display idle sleep.
    private func preventSystemSleep() {
        guard sleepPreventionActivity == nil else {
            return
        }

        let enabledAt = Date()
        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "用户已在划词翻译工具中启用禁止休眠"
        )
        scheduleAutomaticSleepRestoration(enabledAt: enabledAt)
        onStateChange?()
    }

    private func scheduleAutomaticSleepRestoration(enabledAt: Date) {
        guard let restorationDate = Self.automaticSleepRestorationDate(enabledAt: enabledAt) else {
            return
        }

        let timer = Timer(fire: restorationDate, interval: 0, repeats: false) { [weak self] _ in
            self?.restoreSystemSleep()
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticSleepRestorationTimer = timer
    }
}
