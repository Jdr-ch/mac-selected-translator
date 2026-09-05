import AppKit
import Testing
@testable import SelectedTextTranslatorApp

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
    func testStatusItemVisualStyleCombinesTranslationIconAndSleepLight() {
        #expect(StatusItemVisualStyle.itemLength(statusBarThickness: 22) == 44)
        #expect(StatusItemVisualStyle.iconSize == CGSize(width: 26, height: 22))
        #expect(StatusItemVisualStyle.sleepIndicatorHitTargetWidth == 18)
        #expect(StatusItemVisualStyle.sleepIndicatorDiameter == 8)
        #expect(StatusItemVisualStyle.sleepIndicatorCenterOffset == -13)
        #expect(StatusItemVisualStyle.iconCenterOffsetWhilePreventingSleep == 9)
        #expect(StatusItemVisualStyle.idleBreathingDuration == 2.3)
        #expect(StatusItemVisualStyle.idleMotionDuration == 5.76)
        #expect(StatusItemVisualStyle.idleMotionDuration / 1.2 == 4.8)
        #expect(StatusItemVisualStyle.idleFlipTurns == 1)
        #expect(StatusItemVisualStyle.idleRotationTurns == 1)
        #expect(StatusItemVisualStyle.translatingSwapDuration == 1.1)
        #expect(StatusItemVisualStyle.sleepPulseDuration == 1.3)
        #expect(StatusItemVisualStyle.sleepPulseScale > 2)
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
        let initial = try #require(animator.image(at: 0, isDark: false, reduceMotion: false)?.tiffRepresentation)
        let moved = try #require(animator.image(at: 0.8, isDark: false, reduceMotion: false)?.tiffRepresentation)
        #expect(initial != moved)
        let reduced = animator.image(at: 0.8, isDark: false, reduceMotion: true)?.tiffRepresentation
        #expect(initial == reduced)
        animator.isPreventingSleep = true
        let active = try #require(animator.image(at: 0, isDark: false, reduceMotion: true)?.tiffRepresentation)
        #expect(initial != active)
    }

    @Test
    func statusIconRoutesOnlyActiveGreenLightAwayFromNativeMenu() {
        for width: CGFloat in [44, 48, 64] {
            let size = CGSize(width: width, height: 24)
            let greenPoint = CGPoint(x: width / 2 - 13, y: 12)
            let iconPoint = CGPoint(x: width / 2 + 9, y: 12)
            #expect(StatusItemVisualStyle.hitTarget(at: greenPoint, in: size, isPreventingSleep: true) == .sleepIndicator)
            #expect(StatusItemVisualStyle.hitTarget(at: greenPoint, in: size, isPreventingSleep: false) == .menu)
            #expect(StatusItemVisualStyle.hitTarget(at: iconPoint, in: size, isPreventingSleep: true) == .menu)
            #expect(StatusItemVisualStyle.hitTarget(at: CGPoint(x: -1, y: 12), in: size, isPreventingSleep: true) == .outside)
        }
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
