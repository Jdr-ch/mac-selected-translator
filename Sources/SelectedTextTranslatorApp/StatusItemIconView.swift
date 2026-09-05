import AppKit
import QuartzCore

/// Shares one coordinate system between the native button image and its green-light hit region.
enum StatusItemVisualStyle {
    static let iconSize = CGSize(width: 26, height: 22)
    static let sleepIndicatorHitTargetWidth: CGFloat = 18
    static let sleepIndicatorDiameter: CGFloat = 8
    static let sleepIndicatorCenterOffset: CGFloat = -13
    static let iconCenterOffsetWhilePreventingSleep: CGFloat = 9
    static let idleBreathingDuration: TimeInterval = 2.3
    static let idleMotionDuration: TimeInterval = 5.76
    static let idleFlipTurns: CGFloat = 1
    static let idleRotationTurns: CGFloat = 1
    static let translatingSwapDuration: TimeInterval = 1.1
    static let translatingOrbitDuration: TimeInterval = 0.9
    static let sleepPulseDuration: TimeInterval = 1.3
    static let sleepPulseScale: CGFloat = 2.15

    static func itemLength(statusBarThickness: CGFloat) -> CGFloat {
        statusBarThickness * 2
    }

    /// Keeps the larger green-light target independent of its pulse, with the rest owned by AppKit.
    static func hitTarget(at point: CGPoint, in size: CGSize, isPreventingSleep: Bool) -> StatusItemHitTarget {
        guard CGRect(origin: .zero, size: size).contains(point) else {
            return .outside
        }
        let indicatorCenter = size.width / 2 + sleepIndicatorCenterOffset
        if isPreventingSleep,
           abs(point.x - indicatorCenter) < sleepIndicatorHitTargetWidth / 2 {
            return .sleepIndicator
        }
        return .menu
    }
}

enum StatusItemHitTarget {
    case outside
    case menu
    case sleepIndicator
}

enum StatusTranslationIconState {
    case idle
    case translating
}

/// Samples the existing staged motion without depending on a view attached to one particular display.
struct StatusItemTilePose {
    let position: CGPoint
    let flipAngle: CGFloat
    let rotationAngle: CGFloat

    static func idle(at elapsed: TimeInterval, isLatin: Bool) -> StatusItemTilePose {
        let progress = elapsed.truncatingRemainder(dividingBy: StatusItemVisualStyle.idleMotionDuration)
            / StatusItemVisualStyle.idleMotionDuration
        let start = CGPoint(x: isLatin ? 10 : 18, y: isLatin ? 9 : 13)
        let exchanged = CGPoint(x: isLatin ? 18 : 10, y: isLatin ? 13 : 9)
        let lateral = CGPoint(x: start.x, y: exchanged.y)
        let direction: CGFloat = isLatin ? 1 : -1
        let position: CGPoint
        if progress < 0.24 {
            position = interpolate(start, exchanged, progress: progress / 0.24)
        } else if progress < 0.60 {
            position = exchanged
        } else if progress < 0.78 {
            position = interpolate(exchanged, lateral, progress: (progress - 0.60) / 0.18)
        } else {
            position = interpolate(lateral, start, progress: (progress - 0.78) / 0.22)
        }
        return StatusItemTilePose(
            position: position,
            flipAngle: direction * .pi * 2 * StatusItemVisualStyle.idleFlipTurns
                * eased((progress - 0.24) / 0.18),
            rotationAngle: direction * .pi * 2 * StatusItemVisualStyle.idleRotationTurns
                * eased((progress - 0.42) / 0.18)
        )
    }

    static func translating(at elapsed: TimeInterval, isLatin: Bool) -> StatusItemTilePose {
        let progress = elapsed.truncatingRemainder(dividingBy: StatusItemVisualStyle.translatingSwapDuration)
            / StatusItemVisualStyle.translatingSwapDuration
        let fraction = progress < 0.5 ? progress * 2 : (1 - progress) * 2
        return StatusItemTilePose(
            position: interpolate(
                CGPoint(x: isLatin ? 10 : 18, y: isLatin ? 9 : 13),
                CGPoint(x: isLatin ? 18 : 10, y: isLatin ? 13 : 9),
                progress: fraction
            ),
            flipAngle: 0,
            rotationAngle: 0
        )
    }

    private static func interpolate(_ start: CGPoint, _ finish: CGPoint, progress: Double) -> CGPoint {
        let fraction = eased(progress)
        return CGPoint(x: start.x + (finish.x - start.x) * fraction, y: start.y + (finish.y - start.y) * fraction)
    }

    private static func eased(_ progress: Double) -> CGFloat {
        let fraction = min(1, max(0, progress))
        return CGFloat(fraction * fraction * (3 - 2 * fraction))
    }
}

/// Publishes bitmap frames through NSStatusBarButton.image; no child view can steal mouse tracking.
@MainActor
final class StatusItemIconAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private let imageSize: CGSize
    private var frameTimer: Timer?
    private var animationStart = CACurrentMediaTime()

    var animationState: StatusTranslationIconState = .idle {
        didSet {
            guard animationState != oldValue else { return }
            animationStart = CACurrentMediaTime()
            updateImage()
        }
    }

    var isPreventingSleep = false {
        didSet { updateImage() }
    }

    var isSleepIndicatorBright = true {
        didSet { updateImage() }
    }

    init(button: NSStatusBarButton, statusBarThickness: CGFloat) {
        self.button = button
        imageSize = CGSize(
            width: StatusItemVisualStyle.itemLength(statusBarThickness: statusBarThickness),
            height: StatusItemVisualStyle.iconSize.height
        )
        super.init()
    }

    func start() {
        stop()
        updateImage()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateTimer()
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Common run-loop modes keep the animation alive while the native menu is tracking clicks.
    private func updateTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1 / 30, target: self, selector: #selector(updateImage), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    @objc private func displayOptionsDidChange() {
        updateTimer()
        updateImage()
    }

    @objc private func updateImage() {
        guard let button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = image(
            at: CACurrentMediaTime() - animationStart,
            isDark: isDark,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Stores real Retina pixels in the image instead of a view/layer tree that only exists on one screen.
    func image(at elapsed: TimeInterval, isDark: Bool, reduceMotion: Bool) -> NSImage? {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width * scale),
            pixelsHigh: Int(imageSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = imageSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.clear(CGRect(origin: .zero, size: imageSize))
        let time = reduceMotion ? 0 : elapsed
        if isPreventingSleep {
            drawSleepIndicator(in: context, at: time, isDark: isDark, reduceMotion: reduceMotion)
        }
        let offset = isPreventingSleep ? StatusItemVisualStyle.iconCenterOffsetWhilePreventingSleep : 0
        context.translateBy(x: imageSize.width / 2 - 13 + offset, y: 0)
        if animationState == .idle, !reduceMotion {
            let phase = time.truncatingRemainder(dividingBy: StatusItemVisualStyle.idleBreathingDuration)
                / StatusItemVisualStyle.idleBreathingDuration
            let breath = 1 + 0.04 * sin(phase * .pi * 2)
            context.translateBy(x: 13, y: 11)
            context.scaleBy(x: breath, y: breath)
            context.translateBy(x: -13, y: -11)
        }
        let blue = isDark
            ? NSColor(calibratedRed: 0.365, green: 0.667, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.031, green: 0.486, blue: 0.941, alpha: 1)
        let teal = isDark
            ? NSColor(calibratedRed: 0.216, green: 0.82, blue: 0.8, alpha: 1)
            : NSColor(calibratedRed: 0, green: 0.651, blue: 0.651, alpha: 1)
        if animationState == .translating {
            let angle = CGFloat(time / StatusItemVisualStyle.translatingOrbitDuration) * .pi * 2
            context.setStrokeColor(blue.cgColor)
            context.setLineWidth(1.2)
            context.addArc(center: CGPoint(x: 14, y: 11), radius: 9.2, startAngle: angle, endAngle: angle + .pi / 2, clockwise: false)
            context.strokePath()
        }
        for isLatin in [false, true] {
            let pose = animationState == .idle
                ? StatusItemTilePose.idle(at: time, isLatin: isLatin)
                : StatusItemTilePose.translating(at: time, isLatin: isLatin)
            drawTile(in: context, pose: pose, text: isLatin ? "A" : "文", color: isLatin ? blue : teal, isDark: isDark)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: imageSize)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    private func drawTile(in context: CGContext, pose: StatusItemTilePose, text: String, color: NSColor, isDark: Bool) {
        context.saveGState()
        context.translateBy(x: pose.position.x, y: pose.position.y)
        context.rotate(by: pose.rotationAngle)
        let flipScale = cos(pose.flipAngle)
        context.scaleBy(x: abs(flipScale) < 0.015 ? 0.015 : flipScale, y: 1)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: -7, y: -6.5, width: 14, height: 13), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: isDark ? NSColor(calibratedWhite: 0.075, alpha: 1) : NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
        context.restoreGState()
    }

    private func drawSleepIndicator(in context: CGContext, at elapsed: TimeInterval, isDark: Bool, reduceMotion: Bool) {
        let center = CGPoint(x: imageSize.width / 2 + StatusItemVisualStyle.sleepIndicatorCenterOffset, y: imageSize.height / 2)
        let green = isDark
            ? NSColor(calibratedRed: 0.271, green: 0.847, blue: 0.435, alpha: 1)
            : NSColor(calibratedRed: 0.145, green: 0.663, blue: 0.31, alpha: 1)
        context.saveGState()
        if !reduceMotion {
            let phase = elapsed.truncatingRemainder(dividingBy: StatusItemVisualStyle.sleepPulseDuration)
                / StatusItemVisualStyle.sleepPulseDuration
            let radius = StatusItemVisualStyle.sleepIndicatorDiameter / 2
                * (0.65 + phase * (StatusItemVisualStyle.sleepPulseScale - 0.65))
            context.setStrokeColor(green.withAlphaComponent(0.95 * (1 - phase)).cgColor)
            context.setLineWidth(1.8)
            context.setShadow(offset: .zero, blur: 3.5, color: green.withAlphaComponent(0.7 * (1 - phase)).cgColor)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        let radius = StatusItemVisualStyle.sleepIndicatorDiameter / 2
        context.setFillColor(green.withAlphaComponent(isSleepIndicatorBright ? 1 : 0.75).cgColor)
        context.setShadow(offset: .zero, blur: 2.5, color: green.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.restoreGState()
    }
}
