import Foundation

/// Owns the process activity and indicator timing used while idle sleep is disabled.
final class SleepPreventionController: NSObject {
    /// Notifies the owner when the sleep assertion changes so all visible state stays synchronized.
    var onStateChange: (() -> Void)?
    /// Notifies the owner on each flash phase without creating a second menu-bar item.
    var onIndicatorChange: (() -> Void)?

    /// A non-nil activity means both system and display idle sleep are currently blocked.
    private var sleepPreventionActivity: NSObjectProtocol?
    /// The indicator timer runs in common mode so opening a menu does not pause its feedback.
    private var sleepStatusFlashTimer: Timer?
    /// Tracks the current pulse phase and resets to fully bright whenever prevention stops.
    private(set) var isSleepStatusLightBright = true

    /// Drives both the menu action and the green light from the process activity source of truth.
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

    /// Switches between allowing normal idle sleep and preventing both idle sleep modes.
    func toggle() {
        if sleepPreventionActivity == nil {
            preventSystemSleep()
        } else {
            restoreSystemSleep()
        }
    }

    /// Releases the process activity and stops indicator timing during app termination or menu toggle.
    func restoreSystemSleep() {
        if let sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(sleepPreventionActivity)
            self.sleepPreventionActivity = nil
        }
        stopFlashingSleepStatusLight()
        onStateChange?()
    }

    /// Starts one process assertion covering both computer and display idle sleep.
    private func preventSystemSleep() {
        guard sleepPreventionActivity == nil else {
            return
        }

        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "用户已在划词翻译工具中启用禁止休眠"
        )
        startFlashingSleepStatusLight()
        onStateChange?()
    }

    /// Starts a low-frequency flash phase consumed by the app's single combined status item.
    private func startFlashingSleepStatusLight() {
        sleepStatusFlashTimer?.invalidate()
        isSleepStatusLightBright = true

        let timer = Timer(
            timeInterval: 0.65,
            target: self,
            selector: #selector(toggleSleepStatusLightBrightness),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        sleepStatusFlashTimer = timer
    }

    /// Changes only the green light's opacity while the translation icon remains fully visible.
    @objc private func toggleSleepStatusLightBrightness() {
        isSleepStatusLightBright.toggle()
        onIndicatorChange?()
    }

    /// Stops visual feedback and resets the next active state to a fully lit indicator.
    private func stopFlashingSleepStatusLight() {
        sleepStatusFlashTimer?.invalidate()
        sleepStatusFlashTimer = nil
        isSleepStatusLightBright = true
    }
}
