import ApplicationServices
import Testing
@testable import SelectedTextTranslatorApp

/// 完成钩子注入模拟对齐动作，核对触发与窗口范围，不移动任何真实窗口。
@MainActor
struct WorkspaceDesktopCompletionTests {
    private func entry(_ ordinal: Int) -> WorkspaceWindow {
        WorkspaceWindow(bundleID: "com.jetbrains.WebStorm", appName: "WebStorm", title: "项目",
            desktop: WorkspaceDesktop(id: "space-\(ordinal)", displayID: "display", ordinal: ordinal,
                spaceID: UInt64(ordinal), screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
            relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1))
    }

    @Test func eachDesktopAlignsOnceAfterAllItsWindowsSucceed() async {
        let windows = [entry(3), entry(3), entry(4)]
        var results: [WorkspaceOutcome] = []
        var aligned: [Int] = []
        var states: [WorkspaceDesktopActivity] = []
        let completion = WorkspaceDesktopCompletion()
        for window in windows {
            results.append(WorkspaceOutcome(windowID: window.id, label: window.label))
            await completion.finish(window.desktop, windows: windows, outcomes: results,
                align: { aligned.append(window.desktop.ordinal) }, update: { states.append($0) })
            if results.count == 1 { #expect(aligned.isEmpty) }
            if results.count == 2 { #expect(aligned == [3]) }
        }
        await completion.finish(windows[0].desktop, windows: windows, outcomes: results,
            align: { aligned.append(3) }, update: { states.append($0) })
        #expect(aligned == [3, 4])
        #expect(states.filter(\.running).count == 2)
        #expect(states.last?.message == "已恢复并对齐")
    }

    @Test func failedWindowSkipsAlignmentUntilSuccessfulRetry() async {
        let windows = [entry(3), entry(3)]
        var results = windows.map { WorkspaceOutcome(windowID: $0.id, label: $0.label) }
        results[1].error = "打开失败"
        var aligned = 0
        var last: WorkspaceDesktopActivity?
        await WorkspaceDesktopCompletion().finish(windows[0].desktop, windows: windows, outcomes: results,
            align: { aligned += 1 }, update: { last = $0 })
        #expect(aligned == 0)
        #expect(last?.failed == true)
        // 失败重试只替换失败窗口的结果，先前成功窗口仍参与“整个桌面已完成”的判断。
        results[1].error = nil
        await WorkspaceDesktopCompletion().finish(windows[0].desktop, windows: windows, outcomes: results,
            align: { aligned += 1 }, update: { last = $0 })
        #expect(aligned == 1)
        #expect(last?.failed == false)
    }

    @Test func alignmentFailureCanRetryWithExistingResultsAndEmptyDesktopDoesNothing() async {
        let window = entry(3)
        let results = [WorkspaceOutcome(windowID: window.id, label: window.label, nativeWindowID: 42)]
        var attempts = 0
        var last: WorkspaceDesktopActivity?
        await WorkspaceDesktopCompletion().finish(window.desktop, windows: [window], outcomes: results, align: {
            attempts += 1
            throw WorkspaceError.message("窗口不允许调整")
        }, update: { last = $0 })
        #expect(last?.failed == true)
        #expect(last?.message.contains("对齐失败") == true)
        await WorkspaceDesktopCompletion().finish(window.desktop, windows: [window], outcomes: results,
            align: { attempts += 1 }, update: { last = $0 })
        #expect(attempts == 2)
        #expect(last?.message == "已恢复并对齐")
        await WorkspaceDesktopCompletion().finish(window.desktop, windows: [], outcomes: [],
            align: { attempts += 1 }, update: { last = $0 })
        #expect(attempts == 2)
        #expect(last?.failed == false)
    }

    @Test func alignmentOnlyMatchesRestoredIDsOnTargetDesktop() throws {
        let window = entry(3)
        let result = WorkspaceOutcome(windowID: window.id, label: window.label, nativeWindowID: 42)
        let native = WorkspaceNativeWindow(id: 42, element: AXUIElementCreateSystemWide(), bundleID: window.bundleID,
            appName: window.appName, title: window.title, frame: .zero, spaceIDs: [3])
        var unrelated = native
        unrelated.id = 43
        var moved = native
        moved.spaceIDs = [4]
        let selected = try WorkspaceDesktopAlignment.matchingWindows([window], outcomes: [result], available: [unrelated, native], spaceID: 3)
        #expect(selected.map(\.id) == [42])
        #expect(throws: WorkspaceError.self) {
            try WorkspaceDesktopAlignment.matchingWindows([window], outcomes: [result], available: [unrelated, moved], spaceID: 3)
        }
    }
}
