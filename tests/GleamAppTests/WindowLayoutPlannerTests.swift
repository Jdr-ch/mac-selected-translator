import AppKit
import Testing
@testable import GleamApp

/// Locks the user-visible geometry rules without moving real desktop windows during tests.
struct WindowLayoutPlannerTests {
    /// Verifies the sleep menu label exposes the action that matches the current assertion state.
    @Test
    func testSleepPreventionMenuTitleTracksState() {
        #expect(SleepPreventionController.actionTitle(isPreventingSleep: false) == "禁止休眠")
        #expect(SleepPreventionController.actionTitle(isPreventingSleep: true) == "保持休眠")
    }

    /// Verifies the approved icon geometry and animation cadence stay aligned with the design.
    @Test
    func testStatusItemVisualStyleKeepsNativeIconGeometry() {
        #expect(StatusItemVisualStyle.itemLength(statusBarThickness: 22) == 44)
        #expect(StatusItemVisualStyle.iconSize == CGSize(width: 26, height: 22))
        #expect(StatusItemVisualStyle.idleBreathingDuration == 2.3)
        #expect(StatusItemVisualStyle.idleMotionDuration == 5.76)
        #expect(StatusItemVisualStyle.idleMotionDuration / 1.2 == 4.8)
        #expect(StatusItemVisualStyle.idleFlipTurns == 1)
        #expect(StatusItemVisualStyle.idleRotationTurns == 1)
        #expect(StatusItemVisualStyle.translatingSwapDuration == 1.1)
    }

    /// Exercises the actual native status-button image instead of an unrelated standalone NSButton.
    @MainActor
    @Test
    func statusIconUsesNativeImageWithoutClickOverlays() throws {
        let item = NSStatusBar.system.statusItem(withLength: 44)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        let originalSubviews = button.subviews
        let menu = NSMenu()
        item.menu = menu
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: 22)
        animator.start()
        defer { animator.stop() }
        #expect(item.menu === menu)
        #expect(button.subviews == originalSubviews)
        let image = try #require(button.image)
        #expect(!image.isTemplate)
        #expect(image.size == CGSize(width: 44, height: 22))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 88)
        #expect(bitmap.pixelsHigh == 44)
        // 空闲默认静止：连续两帧一致，空闲时不再逐帧重绘。
        let idleStill = try #require(animator.image(at: 0, isDark: false, reduceMotion: false)?.tiffRepresentation)
        let idleLater = try #require(animator.image(at: 0.8, isDark: false, reduceMotion: false)?.tiffRepresentation)
        #expect(idleStill == idleLater)
        // 打开互换后才恢复空闲动效，且仍受减少动态效果约束。
        animator.idleExchangeEnabled = true
        let initial = try #require(animator.image(at: 0, isDark: false, reduceMotion: false)?.tiffRepresentation)
        let moved = try #require(animator.image(at: 0.8, isDark: false, reduceMotion: false)?.tiffRepresentation)
        #expect(initial != moved)
        let reduced = animator.image(at: 0.8, isDark: false, reduceMotion: true)?.tiffRepresentation
        #expect(initial == reduced)
        animator.isPreventingSleep = true
        let active = try #require(animator.image(at: 0, isDark: false, reduceMotion: true)?.tiffRepresentation)
        #expect(initial != active)
    }

    /// 空闲图片不能被同主题通知反复替换，真正切换主题时仍须更新图片与电源前缀。
    @MainActor
    @Test
    func statusIconAppearanceChangesDoNotCreateIdleRedrawLoop() async throws {
        let item = NSStatusBar.system.statusItem(withLength: 44)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.appearance = NSAppearance(named: .aqua)
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: 22)
        var appearanceChanges = 0
        animator.onAppearanceChange = { appearanceChanges += 1 }
        animator.start()
        defer { animator.stop() }
        let initial = try #require(button.image)

        // 显式投递同主题 KVO 通知，复现 AppKit 因图片/布局变化而报告外观的场景。
        for _ in 0..<20 {
            notifyUnchangedStatusIconAppearance(button)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(button.image === initial)
        #expect(appearanceChanges == 1)

        button.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(50))
        let darkImage = try #require(button.image)
        #expect(darkImage !== initial)
        #expect(darkImage.tiffRepresentation != initial.tiffRepresentation)
        #expect(appearanceChanges == 2)

        // 往返切换应恢复相同像素，缓存不能复用另一个主题的文字颜色。
        button.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(50))
        let restored = try #require(button.image)
        #expect(restored.tiffRepresentation == initial.tiffRepresentation)
        #expect(appearanceChanges == 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(button.image === restored)
    }

    /// 空闲交换按帧更新，常驻休眠底色仅随状态切换更新；两者均保持图片对象与按钮几何。
    @MainActor
    @Test(arguments: [false, true])
    func statusIconFramesUpdatePixelsWithoutReplacingNativeImage(sleepOnly: Bool) async throws {
        let item = NSStatusBar.system.statusItem(withLength: 44)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.appearance = NSAppearance(named: .aqua)
        let originalSubviews = button.subviews
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: 22)
        animator.idleExchangeEnabled = !sleepOnly
        animator.isPreventingSleep = sleepOnly
        animator.start()
        defer { animator.stop() }
        let initial = try #require(button.image)
        let initialPixels = try #require(initial.tiffRepresentation)
        let imageFrame = try #require(button.cell).imageRect(forBounds: button.bounds)
        try await Task.sleep(for: .milliseconds(150))
        if sleepOnly {
            // 状态未切换时，时间流逝不能改变底色；关闭后仍保持按钮与原生图片几何。
            #expect(button.image?.tiffRepresentation == initialPixels)
            let bitmap = try #require(initial.representations.first as? NSBitmapImageRep)
            let backgroundColor = try #require(bitmap.colorAt(x: 4, y: 22)?.usingColorSpace(.deviceRGB))
            #expect(backgroundColor.redComponent > backgroundColor.greenComponent + 0.4)
            #expect(backgroundColor.redComponent > backgroundColor.blueComponent + 0.4)
            #expect(backgroundColor.alphaComponent > 0.1)
            animator.isPreventingSleep = false
        }
        #expect(button.image === initial)
        #expect(button.image?.tiffRepresentation != initialPixels)
        #expect(button.cell?.imageRect(forBounds: button.bounds) == imageFrame)
        #expect(button.subviews == originalSubviews)
        let bitmap = try #require(button.image?.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 88 && bitmap.pixelsHigh == 44)
    }

    /// KVO 的成对通知必须在同步调用内完成，不能跨越异步测试的挂起点。
    @MainActor
    private func notifyUnchangedStatusIconAppearance(_ button: NSStatusBarButton) {
        button.willChangeValue(forKey: "effectiveAppearance")
        button.didChangeValue(forKey: "effectiveAppearance")
    }

    @Test
    func statusIconBurstPaletteMatchesModuleAndFailureSemantics() {
        #expect(StatusTranslationIconState.translating.burstStops(isDark: false).count == 2)
        #expect(StatusTranslationIconState.restoringWorkspace.burstStops(isDark: false).count == 1)
        #expect(StatusTranslationIconState.locating.burstStops(isDark: false).count == 1)
        #expect(StatusTranslationIconState.failed.burstStops(isDark: false).count == 1)
        #expect(StatusTranslationIconState.busy.burstStops(isDark: false).count == 4)
    }

    /// 失败态只在短暂抖动期间变化，停留阶段不能继续播放弧线或色散。
    @MainActor
    @Test
    func statusIconFailureStopsAnimatingAfterShake() throws {
        let item = NSStatusBar.system.statusItem(withLength: 44)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        let animator = StatusItemIconAnimator(button: button, statusBarThickness: 22)
        animator.animationState = .failed

        let shaking = try #require(animator.image(at: 0.1, isDark: false, reduceMotion: false)?.tiffRepresentation)
        let settled = try #require(animator.image(at: 0.4, isDark: false, reduceMotion: false)?.tiffRepresentation)
        let settledLater = try #require(animator.image(at: 0.6, isDark: false, reduceMotion: false)?.tiffRepresentation)
        #expect(shaking != settled)
        #expect(settled == settledLater)
    }

    @Test
    func statusIconMotionKeepsExchangeFlipAndRotationInSeparatePhases() {
        let duration = StatusItemVisualStyle.idleMotionDuration
        for isLatin in [true, false] {
            let exchange = StatusItemTilePose.idle(at: duration * 0.12, isLatin: isLatin)
            #expect(exchange.flipAngle == 0)
            #expect(exchange.rotationAngle == 0)
            let flip = StatusItemTilePose.idle(at: duration * 0.33, isLatin: isLatin)
            let rotation = StatusItemTilePose.idle(at: duration * 0.51, isLatin: isLatin)
            #expect(flip.position == rotation.position)
            #expect(abs(abs(flip.flipAngle) - .pi) < 0.0001)
            #expect(flip.rotationAngle == 0)
            #expect(abs(abs(rotation.flipAngle) - .pi * 2) < 0.0001)
            #expect(abs(abs(rotation.rotationAngle) - .pi) < 0.0001)
            let start = StatusItemTilePose.idle(at: 0, isLatin: isLatin)
            #expect(StatusItemTilePose.idle(at: duration, isLatin: isLatin).position == start.position)
        }
    }

    /// Verifies organizing preserves sizes and finds the lowest-overlap edge placement for fixed rectangles.
    @Test
    func testOrganizedFramesPreserveSizesAndMinimizeOverlap() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let frames = [
            CGRect(x: 100, y: 100, width: 600, height: 500),
            CGRect(x: 200, y: 200, width: 600, height: 500),
            CGRect(x: 300, y: 300, width: 400, height: 300)
        ]

        let result = WindowLayoutPlanner.organizedFrames(for: frames, in: screen)

        #expect(result.map(\.size) == frames.map(\.size))
        #expect(result[0].origin == CGPoint(x: 0, y: 0))
        #expect(result[1].origin == CGPoint(x: 400, y: 300))
        #expect(result[2].origin == CGPoint(x: 600, y: 0))
        #expect(result.allSatisfy(screen.contains))
    }

    /// 四个指定应用按各自角位排列，位置随屏幕原点和可用区域变化，尺寸沿用实时窗口值。
    @Test
    func testOrganizedFramesAnchorNamedApplicationsToTheirCorners() {
        let screen = CGRect(x: -1_440, y: 25, width: 1_440, height: 875)
        let frames = [
            CGRect(x: 100, y: 100, width: 400, height: 300),
            CGRect(x: 100, y: 100, width: 500, height: 350),
            CGRect(x: 100, y: 100, width: 400, height: 300),
            CGRect(x: 100, y: 100, width: 500, height: 300)
        ]

        let result = WindowLayoutPlanner.organizedFrames(
            for: frames,
            in: screen,
            bundleIdentifiers: [
                "com.openai.codex",
                "com.tencent.WeWorkMac",
                "com.tencent.xinWeChat",
                "com.ccswitch.desktop"
            ]
        )

        #expect(result == [
            CGRect(x: -1_440, y: 25, width: 400, height: 300),
            CGRect(x: -1_440, y: 550, width: 500, height: 350),
            CGRect(x: -400, y: 600, width: 400, height: 300),
            CGRect(x: -500, y: 25, width: 500, height: 300)
        ])
    }

    /// 即使普通窗口更大且排在输入首位，也必须先为指定应用占位，重复整理保持结果稳定。
    @Test
    func testOrganizedFramesReserveNamedApplicationSpaceBeforeLargerWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let frames = [
            CGRect(x: 200, y: 200, width: 400, height: 800),
            CGRect(x: 100, y: 100, width: 600, height: 500)
        ]
        let bundleIdentifiers = ["com.apple.Terminal", "com.openai.codex"]

        let result = WindowLayoutPlanner.organizedFrames(
            for: frames,
            in: screen,
            bundleIdentifiers: bundleIdentifiers
        )

        #expect(result == [
            CGRect(x: 600, y: 0, width: 400, height: 800),
            CGRect(x: 0, y: 0, width: 600, height: 500)
        ])
        #expect(WindowLayoutPlanner.organizedFrames(
            for: result,
            in: screen,
            bundleIdentifiers: bundleIdentifiers
        ) == result)
    }

    /// Verifies two aligned windows each occupy one full-height half of the screen.
    @Test
    func testAlignedFramesUseFullHeightForTwoWindows() {
        let screen = CGRect(x: -1_440, y: 25, width: 1_440, height: 875)

        let frames = Array(repeating: CGRect(x: 0, y: 0, width: 300, height: 200), count: 2)
        let result = WindowLayoutPlanner.alignedFrames(
            for: frames,
            resizeMask: [true, true],
            in: screen
        )

        #expect(result == [
            CGRect(x: -1_440, y: 25, width: 720, height: 875),
            CGRect(x: -720, y: 25, width: 720, height: 875)
        ])
    }

    /// Verifies first-click resizing releases maximized state before size is written and then restores the anchor.
    @Test
    func testGeometryMutationsMoveBeforeResizing() {
        let frame = CGRect(x: 800, y: 25, width: 800, height: 875)

        #expect(WindowLayoutPlanner.geometryMutations(for: frame, resizesWindow: true) == [
            .position(CGPoint(x: 801, y: 26)),
            .size(CGSize(width: 800, height: 875)),
            .position(CGPoint(x: 800, y: 25))
        ])
        #expect(WindowLayoutPlanner.geometryMutations(for: frame, resizesWindow: false) == [
            .position(CGPoint(x: 800, y: 25))
        ])
    }

    /// Verifies larger sets use the four requested anchors and leave a 200-point vertical offset.
    @Test
    func testAlignedFramesUseFourAnchorsForMoreThanTwoWindows() {
        let screen = CGRect(x: 0, y: 24, width: 1_600, height: 976)

        let frames = Array(repeating: CGRect(x: 0, y: 0, width: 300, height: 200), count: 4)
        let result = WindowLayoutPlanner.alignedFrames(
            for: frames,
            resizeMask: [true, true, true, true],
            in: screen
        )

        #expect(result == [
            CGRect(x: 0, y: 24, width: 800, height: 776),
            CGRect(x: 800, y: 24, width: 800, height: 776),
            CGRect(x: 0, y: 224, width: 800, height: 776),
            CGRect(x: 800, y: 224, width: 800, height: 776)
        ])
    }

    /// Verifies final larger windows take earlier corners and repeated alignment swaps only equal-size windows.
    @Test
    func testAlignedFramesPrioritizeLargeWindowsAndRotateEqualSizes() {
        let screen = CGRect(x: 0, y: 24, width: 1_600, height: 976)
        let frames = [
            CGRect(x: 0, y: 0, width: 400, height: 300),
            CGRect(x: 0, y: 0, width: 500, height: 400),
            CGRect(x: 0, y: 0, width: 600, height: 500),
            CGRect(x: 0, y: 0, width: 300, height: 200)
        ]
        let resizeMask = [true, false, true, false]

        let initial = WindowLayoutPlanner.alignedFrames(
            for: frames,
            resizeMask: resizeMask,
            in: screen
        )
        let rotated = WindowLayoutPlanner.alignedFrames(
            for: initial,
            resizeMask: resizeMask,
            in: screen,
            sameSizeOrderOffset: 1
        )

        #expect(initial.map(\.size) == [
            CGSize(width: 800, height: 776),
            CGSize(width: 500, height: 400),
            CGSize(width: 800, height: 776),
            CGSize(width: 300, height: 200)
        ])
        #expect(initial.map(\.origin) == [
            CGPoint(x: 0, y: 24),
            CGPoint(x: 0, y: 600),
            CGPoint(x: 800, y: 24),
            CGPoint(x: 1_300, y: 800)
        ])
        #expect(rotated.map(\.origin) == [
            CGPoint(x: 800, y: 24),
            CGPoint(x: 0, y: 600),
            CGPoint(x: 0, y: 24),
            CGPoint(x: 1_300, y: 800)
        ])
    }

    /// Verifies the resize policy matches the four live Bundle IDs and rejects unrelated applications.
    @Test
    func testWindowResizePolicyUsesExactApplicationAllowlist() {
        #expect(WindowResizePolicy.allowsResize(bundleIdentifier: "com.jetbrains.WebStorm"))
        #expect(WindowResizePolicy.allowsResize(bundleIdentifier: "com.google.Chrome"))
        #expect(WindowResizePolicy.allowsResize(bundleIdentifier: "com.jetbrains.pycharm"))
        #expect(WindowResizePolicy.allowsResize(bundleIdentifier: "com.coderforart.One-Markdown"))
        #expect(!WindowResizePolicy.allowsResize(bundleIdentifier: "com.apple.Terminal"))
        #expect(!WindowResizePolicy.allowsResize(bundleIdentifier: "com.apple.Safari"))
    }
}
