import AppKit
import QuartzCore

/// 统一 A/文 绘制区域与动画周期；休眠状态使用整组原生图像的静态底色。
enum StatusItemVisualStyle {
    static let iconSize = CGSize(width: 26, height: 22)
    static let idleBreathingDuration: TimeInterval = 2.3
    static let idleMotionDuration: TimeInterval = 5.76
    static let idleFlipTurns: CGFloat = 1
    static let idleRotationTurns: CGFloat = 1
    static let translatingSwapDuration: TimeInterval = 1.1
    static let translatingOrbitDuration: TimeInterval = 0.9
    /// 复杂动效保持 30 帧；休眠底色只在状态切换时更新，不使用刷新计时器。
    static let animationFrameInterval: TimeInterval = 1 / 30

    /// 色散动效：合拢 → 色散 → 绕转 → 收拢，对应 App 图标「一道光被拆成几束」的语言。
    static let dispersionCollapseDuration: TimeInterval = 0.18
    static let dispersionBurstDuration: TimeInterval = 0.35
    static let arcCycleDuration: TimeInterval = 0.9
    static let settleDuration: TimeInterval = 0.25
    static let settleOvershoot: CGFloat = 1.06
    static let failureShakeDuration: TimeInterval = 0.08
    static let failureShakeCycles: CGFloat = 2
    static let failureShakeOffset: CGFloat = 1.5
    static let failureHoldDuration: TimeInterval = 0.4
    static let idleBreathingScale: CGFloat = 0.02

    static let arcRadius: CGFloat = 9.2
    static let arcLineWidth: CGFloat = 1.2
    static let arcGapDegrees: CGFloat = 15
    /// 单色弧不满一圈，留出缺口才像一束被拆开的光。
    static let arcSingleSweepDegrees: CGFloat = 300

    static func itemLength(statusBarThickness: CGFloat) -> CGFloat {
        statusBarThickness * 2
    }
}

/// 每个模块一种色相：弧色与 tile 皮肤都从这里取，只有通用忙碌才走完整四色色散。
enum StatusItemPalette {
    static func blue(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 0.365, green: 0.667, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.031, green: 0.486, blue: 0.941, alpha: 1)
    }

    static func teal(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 0.216, green: 0.82, blue: 0.8, alpha: 1)
            : NSColor(calibratedRed: 0, green: 0.651, blue: 0.651, alpha: 1)
    }

    static func amber(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 1, green: 0.788, blue: 0.365, alpha: 1)
            : NSColor(calibratedRed: 0.859, green: 0.573, blue: 0.043, alpha: 1)
    }

    static func green(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 0.42, green: 0.878, blue: 0.51, alpha: 1)
            : NSColor(calibratedRed: 0.204, green: 0.78, blue: 0.349, alpha: 1)
    }

    static func rose(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 1, green: 0.451, blue: 0.58, alpha: 1)
            : NSColor(calibratedRed: 0.925, green: 0.169, blue: 0.322, alpha: 1)
    }

    static func failure(_ isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedRed: 1, green: 0.42, blue: 0.45, alpha: 1)
            : NSColor(calibratedRed: 0.851, green: 0.157, blue: 0.196, alpha: 1)
    }

    static func dispersion(_ isDark: Bool) -> [NSColor] {
        [blue(isDark), teal(isDark), amber(isDark), rose(isDark)]
    }
}

enum StatusTranslationIconState {
    case idle
    case translating
    case polishing
    case flowcharting
    case restoringWorkspace
    case locating
    /// 通用忙碌 / 多任务并行 / 未知模块，唯一使用完整四色色散的状态。
    case busy
    case failed

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }

    /// 进行中的弧线色停点：有明确模块时只取该模块的颜色。
    func arcStops(isDark: Bool) -> [NSColor] {
        switch self {
        case .idle: return []
        case .translating: return [StatusItemPalette.blue(isDark), StatusItemPalette.teal(isDark)]
        case .polishing: return [StatusItemPalette.teal(isDark), StatusItemPalette.blue(isDark)]
        case .flowcharting: return [StatusItemPalette.teal(isDark), StatusItemPalette.amber(isDark)]
        case .restoringWorkspace: return [StatusItemPalette.green(isDark)]
        case .locating: return [StatusItemPalette.rose(isDark)]
        case .busy: return StatusItemPalette.dispersion(isDark)
        case .failed: return [StatusItemPalette.failure(isDark)]
        }
    }

    /// 色散阶段沿用模块色；只有通用忙碌才展开完整四色，避免单色状态丢失模块语义。
    func burstStops(isDark: Bool) -> [NSColor] {
        self == .busy ? StatusItemPalette.dispersion(isDark) : arcStops(isDark: isDark)
    }

    func tileSpecs(isDark: Bool) -> [StatusItemTileSpec] {
        switch self {
        case .restoringWorkspace:
            return [StatusItemTileSpec(glyph: .windowGrid, color: StatusItemPalette.green(isDark))]
        case .locating:
            return [StatusItemTileSpec(glyph: .locationPin, color: StatusItemPalette.rose(isDark))]
        case .failed:
            let red = StatusItemPalette.failure(isDark)
            return [
                StatusItemTileSpec(glyph: .text("A"), color: red),
                StatusItemTileSpec(glyph: .text("文"), color: red)
            ]
        default:
            return [
                StatusItemTileSpec(glyph: .text("A"), color: StatusItemPalette.blue(isDark)),
                StatusItemTileSpec(glyph: .text("文"), color: StatusItemPalette.teal(isDark))
            ]
        }
    }
}

enum StatusItemTileGlyph {
    case text(String)
    case windowGrid
    case locationPin
}

struct StatusItemTileSpec {
    let glyph: StatusItemTileGlyph
    let color: NSColor
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

    fileprivate static func eased(_ progress: Double) -> CGFloat {
        let fraction = min(1, max(0, progress))
        return CGFloat(fraction * fraction * (3 - 2 * fraction))
    }
}

/// 收拢与色散方向相反：合拢越收越快，色散散得快、收尾慢。
private func easeIn(_ progress: CGFloat) -> CGFloat {
    let fraction = min(1, max(0, progress))
    return fraction * fraction
}

private func easeOut(_ progress: CGFloat) -> CGFloat {
    let fraction = min(1, max(0, progress))
    return 1 - (1 - fraction) * (1 - fraction)
}

/// Publishes bitmap frames through NSStatusBarButton.image; no child view can steal mouse tracking.
@MainActor
final class StatusItemIconAnimator: NSObject {
    /// 静态底图按 point 尺寸、主题与休眠状态缓存；电源前缀对象变化时主动失效。
    private struct BaseImageKey: Equatable {
        let size: CGSize
        let isDark: Bool
        let isPreventingSleep: Bool
    }

    /// 主题切换只使电源静态前缀失效一次，不随动画帧回调。
    var onAppearanceChange: (() -> Void)?
    /// 空闲时是否保留 A/文 互换。默认关闭：空闲不再逐帧重绘，动画全部由状态切换驱动。
    var idleExchangeEnabled = false

    /// 最近已发布的深浅主题；AppKit 的重复外观通知不能再次触发图片赋值。
    private var lastDarkAppearance: Bool?
    /// 字体和字形固定，按主题缓存 A/文 的属性及 point 尺寸，供所有动画帧复用。
    private var textGlyphLayouts: [Bool: [String: TextGlyphLayout]] = [:]
    private weak var button: NSStatusBarButton?
    /// A/文 独立区域的逻辑尺寸，合成时在左侧追加电源前缀的宽度。
    private let imageSize: CGSize
    /// 底色与电源前缀共用一份缓存，翻译动画帧直接复用，避免重复绘制静态内容。
    private var baseImageKey: BaseImageKey?
    private var baseImage: NSImage?
    private var frameTimer: Timer?
    private var failureResetTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var animationStart = CACurrentMediaTime()
    private var settleStart: TimeInterval?
    private var settlingFrom: StatusTranslationIconState?

    var animationState: StatusTranslationIconState = .idle {
        didSet {
            guard animationState != oldValue else { return }
            animationStart = CACurrentMediaTime()
            if animationState == .idle, oldValue.isActive {
                settleStart = animationStart
                settlingFrom = oldValue
            } else {
                settleStart = nil
                settlingFrom = nil
            }
            if animationState == .failed {
                scheduleFailureReset()
            } else {
                failureResetTimer?.invalidate()
                failureResetTimer = nil
            }
            updateTimer()
            updateImage()
        }
    }

    var isPreventingSleep = false {
        didSet { if isPreventingSleep != oldValue { updateImage() } }
    }

    /// 电源模块只在内容或主题变化时替换此位图；保持同一对象时不触发菜单栏重绘。
    var powerPrefixImage: NSImage? {
        didSet {
            guard powerPrefixImage !== oldValue else { return }
            baseImage = nil
            updateImage()
        }
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
        // 减少动态效果会停掉帧计时器，仍需通过外观事件更新静态电源图标。
        appearanceObservation = button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateAppearanceIfNeeded() }
        }
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
        failureResetTimer?.invalidate()
        failureResetTimer = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        NotificationCenter.default.removeObserver(self)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 仅工作动效、收尾或显式空闲交换需要逐帧更新；常驻休眠底色不参与计时。
    private var needsAnimation: Bool {
        guard !reduceMotion else { return false }
        if animationState.isActive || settleStart != nil { return true }
        return idleExchangeEnabled
    }

    /// Common run-loop modes keep the animation alive while the native menu is tracking clicks.
    private func updateTimer() {
        let shouldRun = needsAnimation
        let interval = StatusItemVisualStyle.animationFrameInterval
        if shouldRun, frameTimer?.timeInterval == interval { return }
        frameTimer?.invalidate()
        frameTimer = nil
        guard shouldRun else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(updateImage), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    @objc private func displayOptionsDidChange() {
        updateTimer()
        updateImage()
    }

    /// 图片赋值会间接引发外观通知；只重绘真正变更的主题，截断通知与重绘的反馈循环。
    private func updateAppearanceIfNeeded() {
        // stop() 后可能仍有已排队的 KVO 任务，不能让其重新发布图片。
        guard appearanceObservation != nil, let button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard lastDarkAppearance != isDark else { return }
        updateImage()
    }

    /// 状态和动画帧统一从这里发布；固定尺寸图片复用对象，避免逐帧触发菜单栏宽度重算。
    @objc private func updateImage() {
        guard let button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearanceChanged = lastDarkAppearance != isDark
        if appearanceChanged {
            lastDarkAppearance = isDark
            onAppearanceChange?()
        }
        if let settleStart, CACurrentMediaTime() - settleStart > StatusItemVisualStyle.settleDuration {
            self.settleStart = nil
            settlingFrom = nil
            updateTimer()
        }
        guard let frame = image(
            at: CACurrentMediaTime() - animationStart,
            isDark: isDark,
            reduceMotion: reduceMotion
        ) else { return }
        // 原生图片保持同一尺寸；只使像素缓存失效和标记重绘，不重新设置 image 属性。
        if !appearanceChanged, let published = button.image, published.size == frame.size {
            for representation in published.representations {
                published.removeRepresentation(representation)
            }
            published.addRepresentations(frame.representations)
            published.recache()
            button.needsDisplay = true
        } else {
            // 首帧、主题或尺寸变化才走 AppKit 的完整图片与布局更新。
            button.image = frame
        }
    }

    private func scheduleFailureReset() {
        failureResetTimer?.invalidate()
        let window = StatusItemVisualStyle.failureShakeDuration * 2 * StatusItemVisualStyle.failureShakeCycles
            + StatusItemVisualStyle.failureHoldDuration
        let timer = Timer(timeInterval: window, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.animationState = .idle }
        }
        RunLoop.main.add(timer, forMode: .common)
        failureResetTimer = timer
    }

    /// 电源前缀、底色与 A/文 合成为同一张 Retina 位图，保持原生点击高亮与跨屏复制路径。
    func image(at elapsed: TimeInterval, isDark: Bool, reduceMotion: Bool) -> NSImage? {
        let prefixWidth = powerPrefixImage?.size.width ?? 0
        let size = CGSize(width: prefixWidth + imageSize.width, height: imageSize.height)
        guard let base = cachedBaseImage(size: size, isDark: isDark) else { return nil }
        return bitmapImage(size: size) { context in
            base.draw(in: CGRect(origin: .zero, size: size))
            let time = reduceMotion ? 0 : elapsed
            context.translateBy(x: prefixWidth + imageSize.width / 2 - 13, y: 0)
            context.translateBy(x: shakeOffset(at: time, reduceMotion: reduceMotion), y: 0)
            let settle = settleProgress(reduceMotion: reduceMotion)
            drawScene(in: context, at: time, settle: settle, isDark: isDark, reduceMotion: reduceMotion)
        }
    }

    /// 底色覆盖整组内容；仅尺寸、主题、休眠状态或前缀变化时重新生成静态底图。
    private func cachedBaseImage(size: CGSize, isDark: Bool) -> NSImage? {
        let key = BaseImageKey(size: size, isDark: isDark, isPreventingSleep: isPreventingSleep)
        if baseImageKey == key, let baseImage { return baseImage }
        guard let image = bitmapImage(size: size, draw: { _ in
            if isPreventingSleep {
                // 深浅主题使用不同透明度，使常驻淡红底色与系统点击高亮仍能同时辨认。
                StatusItemPalette.failure(isDark).withAlphaComponent(isDark ? 0.28 : 0.24).setFill()
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 1)
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            }
            if let powerPrefixImage {
                powerPrefixImage.draw(in: CGRect(origin: .zero, size: powerPrefixImage.size))
            }
        }) else { return nil }
        baseImageKey = key
        baseImage = image
        return image
    }

    /// 为底图和动画帧提供相同的 2× 像素与绘制上下文；分配失败时保留上一张已发布图片。
    private func bitmapImage(size: CGSize, draw: (CGContext) -> Void) -> NSImage? {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.clear(CGRect(origin: .zero, size: size))
        draw(context)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    private func settleProgress(reduceMotion: Bool) -> CGFloat? {
        guard !reduceMotion, let settleStart else { return nil }
        let progress = (CACurrentMediaTime() - settleStart) / StatusItemVisualStyle.settleDuration
        guard progress < 1 else { return nil }
        return CGFloat(max(0, progress))
    }

    private func shakeOffset(at time: TimeInterval, reduceMotion: Bool) -> CGFloat {
        guard animationState == .failed, !reduceMotion else { return 0 }
        let halfPeriod = StatusItemVisualStyle.failureShakeDuration
        let window = halfPeriod * 2 * StatusItemVisualStyle.failureShakeCycles
        guard time < window else { return 0 }
        return CGFloat(sin(time / halfPeriod * .pi)) * StatusItemVisualStyle.failureShakeOffset
    }

    // MARK: - 场景绘制

    private func drawScene(
        in context: CGContext,
        at time: TimeInterval,
        settle: CGFloat?,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        let state = animationState
        let specs = state.tileSpecs(isDark: isDark)
        let stops = state.arcStops(isDark: isDark)

        if state.isActive {
            drawActive(in: context, specs: specs, stops: stops, at: time, isDark: isDark, reduceMotion: reduceMotion)
            return
        }
        drawIdle(in: context, specs: specs, at: time, settle: settle, isDark: isDark, reduceMotion: reduceMotion)
    }

    private func drawActive(
        in context: CGContext,
        specs: [StatusItemTileSpec],
        stops: [NSColor],
        at time: TimeInterval,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        let state = animationState
        let burstStops = state.burstStops(isDark: isDark)
        if state == .failed {
            // 失败只保留红色 tile 与外层抖动，不播放成功态的合拢、色散或弧线。
            drawTiles(in: context, specs: specs, placements: restPlacements(specs.count), isDark: isDark)
            return
        }
        if reduceMotion {
            // 降级：弧停在 12 点方向不动，颜色区分保留。
            drawTiles(in: context, specs: specs, placements: restPlacements(specs.count), isDark: isDark)
            drawArc(in: context, stops: stops, angle: -CGFloat.pi / 2, alpha: 1,
                    radius: StatusItemVisualStyle.arcRadius, lineWidth: StatusItemVisualStyle.arcLineWidth)
            return
        }
        let collapse = StatusItemVisualStyle.dispersionCollapseDuration
        let burst = StatusItemVisualStyle.dispersionBurstDuration
        if time < collapse {
            drawCollapse(in: context, specs: specs, stops: stops,
                         progress: easeIn(CGFloat(time / collapse)), isDark: isDark)
        } else if time < collapse + burst {
            drawBurst(in: context, specs: specs, stops: burstStops,
                      progress: easeOut(CGFloat((time - collapse) / burst)), isDark: isDark)
        } else {
            let steady = time - collapse - burst
            var centers = (0..<specs.count).map { restCenter(index: $0, count: specs.count) }
            if state == .translating, specs.count >= 2 {
                centers = (0..<specs.count).map {
                    StatusItemTilePose.translating(at: steady, isLatin: $0 == 0).position
                }
            }
            let placements = centers.map {
                TilePlacement(center: $0, flipAngle: 0, rotationAngle: 0, scale: 1)
            }
            drawTiles(in: context, specs: specs, placements: placements, isDark: isDark)
            let angle = -CGFloat.pi / 2 + CGFloat(steady / StatusItemVisualStyle.arcCycleDuration) * .pi * 2
            drawArc(in: context, stops: stops, angle: angle, alpha: 1,
                    radius: StatusItemVisualStyle.arcRadius, lineWidth: StatusItemVisualStyle.arcLineWidth)
        }
    }

    private func drawIdle(
        in context: CGContext,
        specs: [StatusItemTileSpec],
        at time: TimeInterval,
        settle: CGFloat?,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        var scale: CGFloat = 1
        if let settle {
            let eased = easeOut(settle)
            scale = 1 + (StatusItemVisualStyle.settleOvershoot - 1) * CGFloat(sin(.pi * Double(eased)))
            if let from = settlingFrom, from != .failed {
                let fade = max(0, 1 - easeIn(settle))
                drawArc(
                    in: context,
                    stops: from.arcStops(isDark: isDark),
                    angle: -CGFloat.pi / 2,
                    alpha: fade * 0.9,
                    radius: StatusItemVisualStyle.arcRadius * max(0, 1 - eased),
                    lineWidth: StatusItemVisualStyle.arcLineWidth
                )
            }
        } else if idleExchangeEnabled, !reduceMotion {
            let phase = time.truncatingRemainder(dividingBy: StatusItemVisualStyle.idleBreathingDuration)
                / StatusItemVisualStyle.idleBreathingDuration
            scale = 1 + StatusItemVisualStyle.idleBreathingScale * CGFloat(sin(phase * .pi * 2))
        }

        if idleExchangeEnabled, !reduceMotion {
            let poses = (0..<specs.count).map { StatusItemTilePose.idle(at: time, isLatin: $0 == 0) }
            let placements = poses.map {
                TilePlacement(center: $0.position, flipAngle: $0.flipAngle, rotationAngle: $0.rotationAngle, scale: scale)
            }
            drawTiles(in: context, specs: specs, placements: placements, isDark: isDark)
        } else {
            var placements = restPlacements(specs.count)
            if scale != 1 {
                placements = placements.map {
                    TilePlacement(center: $0.center, flipAngle: 0, rotationAngle: 0, scale: scale)
                }
            }
            drawTiles(in: context, specs: specs, placements: placements, isDark: isDark)
        }
    }

    /// 双卡向中心合拢并压成一条光束。
    private func drawCollapse(
        in context: CGContext,
        specs: [StatusItemTileSpec],
        stops: [NSColor],
        progress: CGFloat,
        isDark: Bool
    ) {
        let fraction = min(1, max(0, progress))
        let centerPoint = CGPoint(x: 14, y: 11)
        let placements = (0..<specs.count).map { index -> TilePlacement in
            let rest = restCenter(index: index, count: specs.count)
            return TilePlacement(
                center: CGPoint(
                    x: rest.x + (centerPoint.x - rest.x) * fraction,
                    y: rest.y + (centerPoint.y - rest.y) * fraction
                ),
                flipAngle: 0,
                rotationAngle: 0,
                scale: max(0.05, 1 - 0.72 * fraction)
            )
        }
        drawTiles(in: context, specs: specs, placements: placements, isDark: isDark, alpha: 1 - 0.8 * fraction)
        guard fraction > 0.05, let leading = stops.first else { return }
        let halfWidth = 11 * fraction
        let rect = CGRect(x: centerPoint.x - halfWidth, y: centerPoint.y - 1.2, width: halfWidth * 2, height: 2.4)
        context.setFillColor(leading.withAlphaComponent(min(1, fraction * 1.4)).cgColor)
        NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
    }

    /// 光束炸开成几道彩带，随后卡片重新浮现。
    private func drawBurst(
        in context: CGContext,
        specs: [StatusItemTileSpec],
        stops: [NSColor],
        progress: CGFloat,
        isDark: Bool
    ) {
        let fraction = min(1, max(0, progress))
        let centerPoint = CGPoint(x: 14, y: 11)
        let colors = stops
        for (index, color) in colors.enumerated() {
            let offset = (CGFloat(index) - CGFloat(colors.count - 1) / 2) * 3.2 * fraction
            let length = 3 + 16 * fraction
            let rect = CGRect(x: centerPoint.x - 1, y: centerPoint.y + offset - 1.2, width: length, height: 2.4)
            context.setFillColor(color.withAlphaComponent(0.95 - 0.35 * fraction).cgColor)
            NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
        }
        let tileFraction = max(0, (fraction - 0.45) / 0.55)
        guard tileFraction > 0 else { return }
        drawTiles(
            in: context,
            specs: specs,
            placements: restPlacements(specs.count, scale: tileFraction),
            isDark: isDark,
            alpha: tileFraction
        )
    }

    /// 分段弧：CGContext 描边不支持直接渐变，逐段填色并在段间留缺口。
    private func drawArc(
        in context: CGContext,
        stops: [NSColor],
        angle: CGFloat,
        alpha: CGFloat,
        radius: CGFloat,
        lineWidth: CGFloat
    ) {
        guard !stops.isEmpty, alpha > 0, radius > 0.5 else { return }
        let center = CGPoint(x: 14, y: 11)
        let count = CGFloat(stops.count)
        let gap = StatusItemVisualStyle.arcGapDegrees * .pi / 180
        let span = count == 1
            ? StatusItemVisualStyle.arcSingleSweepDegrees * .pi / 180
            : (.pi * 2) / count
        for (index, color) in stops.enumerated() {
            let start = angle + CGFloat(index) * span + gap / 2
            let end = start + span - gap
            guard end > start else { continue }
            context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(lineWidth)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.strokePath()
        }
    }

    private struct TilePlacement {
        let center: CGPoint
        let flipAngle: CGFloat
        let rotationAngle: CGFloat
        let scale: CGFloat
    }

    private func restCenter(index: Int, count: Int) -> CGPoint {
        guard count > 1 else { return CGPoint(x: 14, y: 11) }
        return index == 0 ? CGPoint(x: 10, y: 9) : CGPoint(x: 18, y: 13)
    }

    private func restPlacements(_ count: Int, scale: CGFloat = 1) -> [TilePlacement] {
        (0..<count).map {
            TilePlacement(center: restCenter(index: $0, count: count), flipAngle: 0, rotationAngle: 0, scale: scale)
        }
    }

    private func drawTiles(
        in context: CGContext,
        specs: [StatusItemTileSpec],
        placements: [TilePlacement],
        isDark: Bool,
        alpha: CGFloat = 1
    ) {
        for (index, spec) in specs.enumerated() where index < placements.count {
            drawTile(in: context, spec: spec, placement: placements[index], isDark: isDark, alpha: alpha)
        }
    }

    /// 按姿态绘制 tile；文字复用测量结果，保留原来的坐标、字体和即时矢量绘制精度。
    private func drawTile(
        in context: CGContext,
        spec: StatusItemTileSpec,
        placement: TilePlacement,
        isDark: Bool,
        alpha: CGFloat
    ) {
        context.saveGState()
        context.translateBy(x: placement.center.x, y: placement.center.y)
        if placement.rotationAngle != 0 { context.rotate(by: placement.rotationAngle) }
        let flipScale = cos(placement.flipAngle)
        let flip = abs(flipScale) < 0.015 ? 0.015 : flipScale
        context.scaleBy(x: flip * placement.scale, y: placement.scale)
        context.setAlpha(alpha)
        context.setFillColor(spec.color.cgColor)
        context.addPath(CGPath(
            roundedRect: CGRect(x: -7, y: -6.5, width: 14, height: 13),
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        ))
        context.fillPath()
        let ink = isDark
            ? NSColor(calibratedWhite: 0.075, alpha: 1)
            : NSColor.white
        context.setFillColor(ink.cgColor)
        switch spec.glyph {
        case .text(let value):
            let layout = textGlyphLayout(for: value, isDark: isDark, ink: ink)
            (value as NSString).draw(
                at: CGPoint(x: -layout.size.width / 2, y: -layout.size.height / 2),
                withAttributes: layout.attributes
            )
        case .windowGrid:
            let rects = [
                CGRect(x: -4.2, y: -0.2, width: 3.6, height: 2.6),
                CGRect(x: 0.6, y: -0.2, width: 3.6, height: 2.6),
                CGRect(x: -4.2, y: -3.6, width: 8.4, height: 2.6)
            ]
            for rect in rects {
                context.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: 0.7,
                    cornerHeight: 0.7,
                    transform: nil
                ))
                context.fillPath()
            }
        case .locationPin:
            context.addArc(center: CGPoint(x: 0, y: 1.9), radius: 2.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.fillPath()
            context.beginPath()
            context.move(to: CGPoint(x: -1.6, y: 0.2))
            context.addLine(to: CGPoint(x: 1.6, y: 0.2))
            context.addLine(to: CGPoint(x: 0, y: -4.4))
            context.closePath()
            context.fillPath()
        }
        context.restoreGState()
    }

    /// 固定字形的颜色随主题变化，尺寸和字体属性在同一主题内无需逐帧重建。
    private struct TextGlyphLayout {
        let attributes: [NSAttributedString.Key: Any]
        let size: CGSize
    }

    /// 首次遇到字形和主题时测量；后续帧直接复用，深浅主题的文字颜色各自缓存。
    private func textGlyphLayout(for value: String, isDark: Bool, ink: NSColor) -> TextGlyphLayout {
        if let layout = textGlyphLayouts[isDark]?[value] { return layout }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: ink
        ]
        let layout = TextGlyphLayout(
            attributes: attributes,
            size: (value as NSString).size(withAttributes: attributes)
        )
        textGlyphLayouts[isDark, default: [:]][value] = layout
        return layout
    }

}
