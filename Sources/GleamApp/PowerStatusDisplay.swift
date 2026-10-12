import AppKit

/// 方案 C：18pt 双色圆角方块，内部符号最大 15.5pt，电池供电使用蓝色。
@MainActor
enum PowerIconStyle {
    static let size: CGFloat = 18
    static let glyphSize: CGFloat = 15.5

    static func color(for state: PowerState, dark: Bool) -> NSColor {
        switch state {
        case .charging:
            return dark ? NSColor(red: 0.40, green: 0.89, blue: 0.59, alpha: 1)
                : NSColor(red: 0.08, green: 0.50, blue: 0.27, alpha: 1)
        case .externalPower:
            return dark ? NSColor(red: 0.95, green: 0.75, blue: 0.42, alpha: 1)
                : NSColor(red: 0.64, green: 0.40, blue: 0.06, alpha: 1)
        case .battery:
            return dark ? NSColor(red: 0.48, green: 0.69, blue: 1, alpha: 1)
                : NSColor(red: 0.16, green: 0.40, blue: 0.79, alpha: 1)
        case .unavailable: return dark ? .lightGray : .darkGray
        }
    }

    /// 输出实际 Retina 位图，供原生状态项图像合成与跨屏显示；不创建自绘子视图。
    static func image(for state: PowerState, dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: 2, y: 2)
        let color = color(for: state, dark: dark)
        color.withAlphaComponent(dark ? 0.23 : 0.15).setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: image.size), xRadius: 4.2, yRadius: 4.2).fill()
        let symbol: String
        switch state {
        case .charging: symbol = "bolt.fill"
        case .externalPower: symbol = "powerplug.fill"
        case .battery: symbol = "battery.100percent"
        case .unavailable: symbol = "questionmark"
        }
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: state.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
            let factor = min(glyphSize / glyph.size.width, glyphSize / glyph.size.height)
            let fitted = CGSize(width: glyph.size.width * factor, height: glyph.size.height * factor)
            glyph.draw(in: CGRect(x: (size - fitted.width) / 2, y: (size - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}

/// 缓存电源文字与方块，交给菜单栏图像合成器统一绘制底色及 A/文动画。
@MainActor
final class PowerStatusDisplay {
    private struct CacheKey: Equatable {
        let state: PowerState
        let value: String
        let dark: Bool
    }
    private var lastKey: CacheKey?
    private var badges: [PowerState: NSImage] = [:]
    private var cachedDark: Bool?
    private(set) var renderCount = 0
    /// 仅显示内容或主题变化时替换对象；动画帧复用此静态前缀。
    private(set) var image: NSImage?

    /// 从按钮读取深浅主题并缓存前缀位图，不再设置标题附件或改变按钮的点击链路。
    func update(_ presentation: PowerPresentation, button: NSStatusBarButton) {
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = CacheKey(state: presentation.state, value: presentation.menuValue, dark: dark)
        guard key != lastKey else { return }
        if cachedDark != dark {
            badges.removeAll()
            cachedDark = dark
        }
        let badge = badges[key.state] ?? PowerIconStyle.image(for: key.state, dark: dark)
        badges[key.state] = badge
        let valueWidth: CGFloat = key.value.isEmpty ? 0 : 63
        let size = NSSize(width: valueWidth + PowerIconStyle.size + 3, height: 22)
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: 44,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: 2, y: 2)
        if !key.value.isEmpty {
            let text = NSAttributedString(string: key.value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: dark ? NSColor.white : NSColor.black
            ])
            text.draw(at: CGPoint(x: valueWidth - text.size().width - 6, y: (22 - text.size().height) / 2))
        }
        badge.draw(in: CGRect(x: valueWidth, y: 2, width: PowerIconStyle.size, height: PowerIconStyle.size))
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        image.isTemplate = false
        self.image = image
        lastKey = key
        renderCount += 1
    }
}
