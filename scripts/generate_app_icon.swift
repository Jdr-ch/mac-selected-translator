#!/usr/bin/env swift

import AppKit
import Foundation

private let designSize: CGFloat = 1024

/// Converts a hexadecimal RGB value into the calibrated color used by the menu-bar mark.
private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

/// Draws one rounded language tile with a centered glyph and a soft depth shadow.
private func drawTile(
    _ rect: CGRect,
    fillColor: NSColor,
    glyph: String,
    glyphSize: CGFloat,
    context: CGContext
) {
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 30,
        color: color(0x102A33, alpha: 0.24).cgColor
    )
    fillColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 82, yRadius: 82).fill()
    context.restoreGState()

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: glyphSize, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let renderedGlyphSize = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: CGPoint(
            x: rect.midX - renderedGlyphSize.width / 2,
            y: rect.midY - renderedGlyphSize.height / 2 + 6
        ),
        withAttributes: attributes
    )
}

/// Renders the same overlapping blue and teal language cards at one iconset pixel size.
private func renderIcon(pixelSize: Int, outputURL: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to create icon bitmap context"
        ])
    }

    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixelSize) / designSize, y: CGFloat(pixelSize) / designSize)
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let backgroundRect = CGRect(x: 62, y: 62, width: 900, height: 900)
    color(0xF4FAFB).setFill()
    NSBezierPath(roundedRect: backgroundRect, xRadius: 205, yRadius: 205).fill()
    color(0xD5E3E7).setStroke()
    let outline = NSBezierPath(roundedRect: backgroundRect, xRadius: 205, yRadius: 205)
    outline.lineWidth = 10
    outline.stroke()

    drawTile(
        CGRect(x: 405, y: 408, width: 430, height: 388),
        fillColor: color(0x00A6A6),
        glyph: "文",
        glyphSize: 190,
        context: context
    )
    drawTile(
        CGRect(x: 188, y: 228, width: 430, height: 388),
        fillColor: color(0x087CF0),
        glyph: "A",
        glyphSize: 210,
        context: context
    )

    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Unable to finalize icon bitmap"
        ])
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Unable to encode icon PNG"
        ])
    }
    try data.write(to: outputURL, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate_app_icon.swift <AppIcon.iconset>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let specifications: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixelSize) in specifications {
    try renderIcon(pixelSize: pixelSize, outputURL: outputDirectory.appendingPathComponent(filename))
}
