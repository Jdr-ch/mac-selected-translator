import Foundation
import Testing
@testable import SelectedTextTranslatorApp

struct SleepPreventionControllerTests {
    @MainActor
    @Test
    func screenLockRestoresSleepWithoutReenablingOnUnlock() {
        let notificationCenter = NotificationCenter()
        let controller = SleepPreventionController(screenLockNotificationCenter: notificationCenter)
        defer { controller.restoreSystemSleep() }
        var stateChangeCount = 0
        controller.onStateChange = { stateChangeCount += 1 }

        controller.toggle()
        #expect(controller.isPreventingSleep)

        notificationCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        #expect(!controller.isPreventingSleep)
        #expect(controller.actionTitle == "禁止休眠")
        #expect(controller.isSleepStatusLightBright)
        #expect(stateChangeCount == 2)

        notificationCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        #expect(!controller.isPreventingSleep)
        #expect(stateChangeCount == 2)
    }

    @MainActor
    @Test
    func screenLockDoesNotChangeAlreadyDisabledState() {
        let notificationCenter = NotificationCenter()
        let controller = SleepPreventionController(screenLockNotificationCenter: notificationCenter)
        var stateChangeCount = 0
        controller.onStateChange = { stateChangeCount += 1 }

        notificationCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        #expect(!controller.isPreventingSleep)
        #expect(stateChangeCount == 0)
    }

    @Test(arguments: [
        "2026-09-05T00:00:00+08:00",
        "2026-09-05T09:00:00+08:00",
        "2026-09-05T18:29:59+08:00"
    ])
    func enablingBeforeCutoffSchedulesSameDayRestoration(_ timestamp: String) throws {
        let formatter = ISO8601DateFormatter()
        let enabledAt = try #require(formatter.date(from: timestamp))
        let expected = try #require(formatter.date(from: "2026-09-05T18:30:00+08:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))

        #expect(SleepPreventionController.automaticSleepRestorationDate(
            enabledAt: enabledAt,
            calendar: calendar
        ) == expected)
    }

    @Test(arguments: [
        "2026-09-05T18:30:00+08:00",
        "2026-09-05T18:30:01+08:00",
        "2026-09-05T23:59:59+08:00"
    ])
    func enablingAtOrAfterCutoffDoesNotScheduleRestoration(_ timestamp: String) throws {
        let formatter = ISO8601DateFormatter()
        let enabledAt = try #require(formatter.date(from: timestamp))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))

        #expect(SleepPreventionController.automaticSleepRestorationDate(
            enabledAt: enabledAt,
            calendar: calendar
        ) == nil)
    }
}
