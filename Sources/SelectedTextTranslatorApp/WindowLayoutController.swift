import AppKit
import ApplicationServices

/// Describes user-actionable failures from menu-triggered window layout commands.
enum WindowLayoutError: LocalizedError {
    case accessibilityPermissionMissing
    case noEligibleWindows
    case unableToUpdateWindows

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "窗口布局需要辅助功能权限，请在系统设置中授权后重试。"
        case .noEligibleWindows:
            return "当前屏幕没有可整理的应用窗口。"
        case .unableToUpdateWindows:
            return "没有窗口完成调整，请确认相关应用允许辅助功能控制。"
        }
    }
}

/// Restricts alignment resizing to the four applications named by the user.
struct WindowResizePolicy {
    private static let resizableBundleIdentifiers: Set<String> = [
        "com.jetbrains.webstorm",
        "com.google.chrome",
        "com.jetbrains.pycharm",
        "com.coderforart.one-markdown"
    ]

    /// Returns whether alignment may change the window size for one running application.
    static func allowsResize(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return resizableBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }
}

/// Describes the ordered Accessibility writes needed to apply one planned window frame.
enum WindowGeometryMutation: Equatable {
    case position(CGPoint)
    case size(CGSize)
}

/// Calculates target geometry independently from Accessibility side effects.
struct WindowLayoutPlanner {
    /// Places fixed-size windows against screen or window edges, choosing the lowest-overlap candidate each time.
    static func organizedFrames(for frames: [CGRect], in screen: CGRect) -> [CGRect] {
        guard !frames.isEmpty, screen.width > 0, screen.height > 0 else {
            return []
        }

        // Larger visible windows claim space first so smaller windows can fill the remaining gaps with less overlap.
        let orderedIndexes = frames.indices.sorted { left, right in
            let leftArea = visibleArea(of: frames[left].size, in: screen)
            let rightArea = visibleArea(of: frames[right].size, in: screen)
            if leftArea == rightArea {
                return frames[left].height > frames[right].height
            }
            return leftArea > rightArea
        }
        var result = frames
        var placedVisibleFrames: [CGRect] = []

        for index in orderedIndexes {
            let size = frames[index].size
            let origin = bestOrganizedOrigin(
                for: size,
                in: screen,
                around: placedVisibleFrames
            )
            let frame = CGRect(origin: origin, size: size)
            result[index] = frame
            placedVisibleFrames.append(frame.intersection(screen))
        }

        return result
    }

    /// Assigns larger final window sizes to earlier corners and preserves sizes outside the resize policy.
    static func alignedFrames(
        for frames: [CGRect],
        resizeMask: [Bool],
        in screen: CGRect,
        sameSizeOrderOffset: Int = 0
    ) -> [CGRect] {
        guard !frames.isEmpty, screen.width > 0, screen.height > 0 else {
            return []
        }

        let windowCount = frames.count
        let width = screen.width / 2
        let height = windowCount <= 2 ? screen.height : max(screen.height - 200, 1)
        let targetSizes = frames.indices.map { index in
            let shouldResize = resizeMask.indices.contains(index) && resizeMask[index]
            return shouldResize ? CGSize(width: width, height: height) : frames[index].size
        }
        let orderedIndexes = alignmentIndexes(
            for: targetSizes,
            sameSizeOrderOffset: sameSizeOrderOffset
        )
        var result = frames

        for (positionInSequence, index) in orderedIndexes.enumerated() {
            let size = targetSizes[index]
            let cornerIndex = positionInSequence % 4
            result[index] = CGRect(
                origin: anchoredOrigin(for: size, cornerIndex: cornerIndex, in: screen),
                size: size
            )
        }
        return result
    }

    /// Sorts by final displayed area, then rotates only equal-size groups on repeated alignment clicks.
    private static func alignmentIndexes(
        for sizes: [CGSize],
        sameSizeOrderOffset: Int
    ) -> [Int] {
        let sortedIndexes = sizes.indices.sorted { left, right in
            let leftArea = sizes[left].width * sizes[left].height
            let rightArea = sizes[right].width * sizes[right].height
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            if sizes[left].width != sizes[right].width {
                return sizes[left].width > sizes[right].width
            }
            if sizes[left].height != sizes[right].height {
                return sizes[left].height > sizes[right].height
            }
            return left < right
        }
        var orderedIndexes: [Int] = []
        var groupStart = 0

        while groupStart < sortedIndexes.count {
            let groupSize = sizes[sortedIndexes[groupStart]]
            var groupEnd = groupStart + 1
            while groupEnd < sortedIndexes.count, sizes[sortedIndexes[groupEnd]] == groupSize {
                groupEnd += 1
            }

            let group = Array(sortedIndexes[groupStart..<groupEnd])
            let offset = ((sameSizeOrderOffset % group.count) + group.count) % group.count
            orderedIndexes.append(contentsOf: group[offset...])
            orderedIndexes.append(contentsOf: group[..<offset])
            groupStart = groupEnd
        }
        return orderedIndexes
    }

    /// Moves a resizable window before sizing to release maximized state, then restores its requested anchor.
    static func geometryMutations(
        for frame: CGRect,
        resizesWindow: Bool
    ) -> [WindowGeometryMutation] {
        guard resizesWindow else {
            return [.position(frame.origin)]
        }
        let releaseOrigin = CGPoint(x: frame.origin.x + 1, y: frame.origin.y + 1)
        return [
            .position(releaseOrigin),
            .size(frame.size),
            .position(frame.origin)
        ]
    }

    /// Returns how much of one fixed-size window can contribute to visible screen coverage.
    private static func visibleArea(of size: CGSize, in screen: CGRect) -> CGFloat {
        min(size.width, screen.width) * min(size.height, screen.height)
    }

    /// Evaluates screen edges and edges beside placed windows, preferring minimum overlap then top-left order.
    private static func bestOrganizedOrigin(
        for size: CGSize,
        in screen: CGRect,
        around placedFrames: [CGRect]
    ) -> CGPoint {
        let maximumX = max(screen.minX, screen.maxX - size.width)
        let maximumY = max(screen.minY, screen.maxY - size.height)
        var xCandidates: Set<CGFloat> = [screen.minX, maximumX]
        var yCandidates: Set<CGFloat> = [screen.minY, maximumY]

        for placedFrame in placedFrames {
            xCandidates.insert(min(max(placedFrame.maxX, screen.minX), maximumX))
            xCandidates.insert(min(max(placedFrame.minX - size.width, screen.minX), maximumX))
            yCandidates.insert(min(max(placedFrame.maxY, screen.minY), maximumY))
            yCandidates.insert(min(max(placedFrame.minY - size.height, screen.minY), maximumY))
        }

        var bestOrigin = CGPoint(x: screen.minX, y: screen.minY)
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        for y in yCandidates.sorted() {
            for x in xCandidates.sorted() {
                let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size).intersection(screen)
                let overlap = placedFrames.reduce(CGFloat.zero) { total, placedFrame in
                    total + intersectionArea(candidate, placedFrame)
                }
                if overlap < bestOverlap {
                    bestOverlap = overlap
                    bestOrigin = CGPoint(x: x, y: y)
                }
            }
        }
        return bestOrigin
    }

    /// Measures visible overlap for the organizer's deterministic candidate comparison.
    private static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Anchors one preserved or resized frame to the requested corner without pushing its top-left off screen.
    private static func anchoredOrigin(
        for size: CGSize,
        cornerIndex: Int,
        in screen: CGRect
    ) -> CGPoint {
        let isRight = cornerIndex == 1 || cornerIndex == 3
        let isBottom = cornerIndex == 2 || cornerIndex == 3
        return CGPoint(
            x: isRight ? max(screen.minX, screen.maxX - size.width) : screen.minX,
            y: isBottom ? max(screen.minY, screen.maxY - size.height) : screen.minY
        )
    }
}

@MainActor
/// Finds windows on the active Space and applies planner results through the Accessibility API.
final class WindowLayoutController {
    /// Couples one controllable AX element with the frame used as planner input.
    private struct ManagedWindow {
        let element: AXUIElement
        let frame: CGRect
        let bundleIdentifier: String?
    }

    /// Carries the front-to-back CGWindow snapshot used to exclude other Spaces.
    private struct VisibleWindow {
        let processIdentifier: pid_t
        let frame: CGRect
        let bundleIdentifier: String?
    }

    /// Stores the last successful assignment so an unchanged layout rotates only equal-size windows on the next click.
    private struct AlignmentSnapshot {
        let elements: [AXUIElement]
        let targetFrames: [CGRect]
        /// Counts consecutive clicks on an intact result; each equal-size group normalizes it by its own count.
        let sameSizeOrderOffset: Int
    }

    /// Cleared after organizing; a mismatched window set or frame resets the next alignment to the first order.
    private var alignmentSnapshot: AlignmentSnapshot?

    /// Rearranges windows on the pointer's screen without changing their current sizes.
    func organizeCurrentScreen() throws {
        let context = try currentLayoutContext()
        let targetFrames = WindowLayoutPlanner.organizedFrames(
            for: context.windows.map(\.frame),
            in: context.screenFrame
        )
        try apply(
            targetFrames,
            to: context.windows,
            resizeMask: Array(repeating: false, count: context.windows.count)
        )
        alignmentSnapshot = nil
    }

    /// Applies selective resizing and rotates equal-size assignments when the previous result is still intact.
    func alignCurrentScreen() throws {
        let context = try currentLayoutContext()
        let cycle = alignmentCycle(for: context.windows)
        let resizeMask = cycle.windows.map {
            WindowResizePolicy.allowsResize(bundleIdentifier: $0.bundleIdentifier)
        }
        let targetFrames = WindowLayoutPlanner.alignedFrames(
            for: cycle.windows.map(\.frame),
            resizeMask: resizeMask,
            in: context.screenFrame,
            sameSizeOrderOffset: cycle.sameSizeOrderOffset
        )
        try apply(
            targetFrames,
            to: cycle.windows,
            resizeMask: resizeMask
        )
        alignmentSnapshot = AlignmentSnapshot(
            elements: cycle.windows.map(\.element),
            targetFrames: targetFrames,
            sameSizeOrderOffset: cycle.sameSizeOrderOffset
        )
    }

    /// Resolves the current screen and matches its visible Core Graphics windows to controllable AX windows.
    private func currentLayoutContext() throws -> (screenFrame: CGRect, windows: [ManagedWindow]) {
        guard AXIsProcessTrusted() else {
            throw WindowLayoutError.accessibilityPermissionMissing
        }
        guard let screen = screenUnderPointer() else {
            throw WindowLayoutError.noEligibleWindows
        }

        let screenFrame = accessibilityFrame(for: screen.visibleFrame)
        let visibleWindows = visibleWindows(on: screenFrame)
        let windows = managedWindows(matching: visibleWindows)
        guard !windows.isEmpty else {
            throw WindowLayoutError.noEligibleWindows
        }
        return (screenFrame, windows)
    }

    /// Uses the pointer position because the status icon can be opened from any attached display.
    private func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    /// Converts AppKit's bottom-left coordinates to the top-left global coordinates used by AX and CGWindow.
    private func accessibilityFrame(for appKitFrame: CGRect) -> CGRect {
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? appKitFrame.maxY
        return CGRect(
            x: appKitFrame.minX,
            y: primaryScreenTop - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    /// Reads front-to-back windows from the current Space and keeps those centered on the target screen.
    private func visibleWindows(on screen: CGRect) -> [VisibleWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let processIdentifier = info[kCGWindowOwnerPID as String] as? pid_t,
                processIdentifier != ProcessInfo.processInfo.processIdentifier,
                let app = NSRunningApplication(processIdentifier: processIdentifier),
                app.activationPolicy == .regular,
                !app.isHidden,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                screen.contains(CGPoint(x: frame.midX, y: frame.midY))
            else {
                return nil
            }
            return VisibleWindow(
                processIdentifier: processIdentifier,
                frame: frame,
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }

    /// Matches on-screen CG frames to AX elements so windows on other Spaces are never modified.
    private func managedWindows(matching visibleWindows: [VisibleWindow]) -> [ManagedWindow] {
        let groupedWindows = Dictionary(grouping: visibleWindows, by: \.processIdentifier)
        var candidatesByProcess = groupedWindows.mapValues { visibleForProcess in
            accessibilityWindows(
                for: visibleForProcess[0].processIdentifier,
                bundleIdentifier: visibleForProcess[0].bundleIdentifier
            )
        }
        var result: [ManagedWindow] = []

        for visibleWindow in visibleWindows {
            guard var candidates = candidatesByProcess[visibleWindow.processIdentifier] else {
                continue
            }
            guard let matchIndex = candidates.indices.min(by: { left, right in
                frameDistance(candidates[left].frame, visibleWindow.frame)
                    < frameDistance(candidates[right].frame, visibleWindow.frame)
            }) else {
                continue
            }

            let match = candidates[matchIndex]
            // CG and AX frames can differ by a small title-bar or border offset; larger gaps indicate another window.
            guard frameDistance(match.frame, visibleWindow.frame) <= 80 else {
                continue
            }
            result.append(match)
            candidates.remove(at: matchIndex)
            candidatesByProcess[visibleWindow.processIdentifier] = candidates
        }

        return result
    }

    /// Returns movable, non-minimized application windows; size capability is only used by the selective policy.
    private func accessibilityWindows(
        for processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> [ManagedWindow] {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let elements: [AXUIElement] = attributeValue(
            of: appElement,
            attribute: kAXWindowsAttribute as CFString
        ) else {
            return []
        }

        return elements.compactMap { element in
            guard
                attributeValue(of: element, attribute: kAXMinimizedAttribute as CFString) != true,
                isAttributeSettable(kAXPositionAttribute as CFString, on: element),
                let position = pointValue(of: element, attribute: kAXPositionAttribute as CFString),
                let size = sizeValue(of: element, attribute: kAXSizeAttribute as CFString)
            else {
                return nil
            }
            return ManagedWindow(
                element: element,
                frame: CGRect(origin: position, size: size),
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    /// Applies ordered AX writes so maximized target apps resize on the first alignment click.
    private func apply(
        _ frames: [CGRect],
        to windows: [ManagedWindow],
        resizeMask: [Bool]
    ) throws {
        var updatedWindowCount = 0

        for (index, pair) in zip(windows, frames).enumerated() {
            let (window, frame) = pair
            let shouldResize = resizeMask.indices.contains(index) && resizeMask[index]
            let mutations = WindowLayoutPlanner.geometryMutations(
                for: frame,
                resizesWindow: shouldResize
            )
            let didApplyEveryMutation = mutations.allSatisfy { mutation in
                switch mutation {
                case .position(let position):
                    return setPosition(position, on: window.element)
                case .size(let size):
                    return setSize(size, on: window.element)
                }
            }
            if didApplyEveryMutation {
                updatedWindowCount += 1
            }
        }

        guard updatedWindowCount > 0 else {
            throw WindowLayoutError.unableToUpdateWindows
        }
    }

    /// Advances equal-size rotation only while the same windows remain at the last assigned frames.
    private func alignmentCycle(
        for currentWindows: [ManagedWindow]
    ) -> (windows: [ManagedWindow], sameSizeOrderOffset: Int) {
        guard
            let alignmentSnapshot,
            let orderedWindows = windows(
                currentWindows,
                orderedBy: alignmentSnapshot.elements
            ),
            zip(orderedWindows.map(\.frame), alignmentSnapshot.targetFrames).allSatisfy({
                frameDistance($0.0, $0.1) <= 24
            })
        else {
            return (currentWindows, 0)
        }

        let nextOffset = alignmentSnapshot.sameSizeOrderOffset + 1
        return (orderedWindows, nextOffset)
    }

    /// Restores the snapshot's stable sequence even if front-to-back CGWindow ordering has changed.
    private func windows(
        _ currentWindows: [ManagedWindow],
        orderedBy elements: [AXUIElement]
    ) -> [ManagedWindow]? {
        guard currentWindows.count == elements.count else {
            return nil
        }

        var remainingWindows = currentWindows
        var orderedWindows: [ManagedWindow] = []
        for element in elements {
            guard let index = remainingWindows.firstIndex(where: { CFEqual($0.element, element) }) else {
                return nil
            }
            orderedWindows.append(remainingWindows.remove(at: index))
        }
        return orderedWindows
    }

    /// Measures coordinate and size differences when pairing CGWindow and AX representations.
    private func frameDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }

    /// Reads a typed Accessibility attribute when the app exposes that value.
    private func attributeValue<T>(of element: AXUIElement, attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? T
    }

    /// Reads an Accessibility point value used for top-left window positioning.
    private func pointValue(of element: AXUIElement, attribute: CFString) -> CGPoint? {
        guard let value: AXValue = attributeValue(of: element, attribute: attribute) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    /// Reads an Accessibility size value used for window geometry matching.
    private func sizeValue(of element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let value: AXValue = attributeValue(of: element, attribute: attribute) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }

    /// Checks whether an AX window lets this app write one geometry attribute.
    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success
            && isSettable.boolValue
    }

    /// Writes the AX position and returns whether macOS accepted the change.
    private func setPosition(_ position: CGPoint, on element: AXUIElement) -> Bool {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    /// Writes the AX size and reports whether the target application accepted the change.
    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }
}
