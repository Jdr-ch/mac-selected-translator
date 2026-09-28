import Testing
@testable import GleamApp

/// 系统依赖均为闭包，不激活真实应用或发送复制快捷键。
@Suite(.serialized)
@MainActor
struct SelectionCaptureTests {
    @Test func accessibilitySuccessDoesNotActivateOrCopy() async throws {
        let capture = SelectionCapture(sourcePID: 10, ownPID: 20, foregroundPID: { 20 },
                                       activateSource: { Issue.record("AX 成功不应激活应用"); return false },
                                       accessibilityText: { " 选区 \n" },
                                       copiedText: { Issue.record("AX 成功不应复制"); return nil })
        #expect(try await capture.read(restoreSourceFocus: true) == "选区")
    }

    @Test func restoresOnlyOwnPopoverFocusAndWaitsBeforeCopy() async throws {
        var foreground: Int32 = 20
        var activated = 0
        var waited = 0
        var copied = 0
        let capture = SelectionCapture(sourcePID: 10, ownPID: 20, foregroundPID: { foreground },
                                       activateSource: { activated += 1; return true }, accessibilityText: { nil },
                                       copiedText: { copied += 1; #expect(foreground == 10); return "新选区" },
                                       waitForFocus: { waited += 1; foreground = 10 })
        #expect(try await capture.read(restoreSourceFocus: true) == "新选区")
        #expect(activated == 1 && waited == 1 && copied == 1)
    }

    @Test func thirdApplicationNeverReceivesCopyOrLosesFocus() async {
        for initial in [Int32(30), 20] {
            var foreground = initial
            let capture = SelectionCapture(sourcePID: 10, ownPID: 20, foregroundPID: { foreground },
                                           activateSource: { true }, accessibilityText: { nil },
                                           copiedText: { Issue.record("不得向第三应用复制"); return nil },
                                           waitForFocus: { foreground = 30 })
            await #expect(throws: TranslatorAppError.self) { try await capture.read(restoreSourceFocus: true) }
        }
    }

    @Test func failedActivationEmptyCopyAndFocusTimeoutNeverReturnOldText() async {
        for mode in 0..<3 {
            let capture = SelectionCapture(sourcePID: 10, ownPID: 20, foregroundPID: { mode == 1 ? 10 : 20 },
                                           activateSource: { mode != 0 }, accessibilityText: { " " },
                                           copiedText: { nil }, waitForFocus: {})
            await #expect(throws: TranslatorAppError.self) { try await capture.read(restoreSourceFocus: true) }
        }
    }

    @Test func shortcutPathDoesNotActivateAndCancellationPreventsCopy() async {
        let capture = SelectionCapture(sourcePID: 10, ownPID: 20, foregroundPID: { 20 },
                                       activateSource: { Issue.record("快捷键路径不主动激活"); return true },
                                       accessibilityText: { nil }, copiedText: { Issue.record("不应复制"); return nil })
        await #expect(throws: TranslatorAppError.self) { try await capture.read(restoreSourceFocus: false) }
        let task = Task { try await capture.read(restoreSourceFocus: true) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
