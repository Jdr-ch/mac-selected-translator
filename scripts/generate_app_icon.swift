#!/usr/bin/env swift

import AppKit
import Foundation

/// 图标主图（1024×1024，圆角外已透明）由设计稿产出后放在 assets/ 下，
/// 本脚本只负责把它高质量缩放成 macOS iconset 需要的各个尺寸。

private func resolveMasterPath() -> String {
    if CommandLine.arguments.count > 2 {
        return CommandLine.arguments[2]
    }
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
    let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    return rootURL.appendingPathComponent("assets/AppIconMaster.png").path
}

private func renderIcon(pixelSize: Int, master: CGImage, outputURL: URL) throws {
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
    context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.draw(master, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

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

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data(
        "usage: generate_app_icon.swift <AppIcon.iconset> [master.png]\n".utf8
    ))
    exit(64)
}

let masterPath = resolveMasterPath()
guard FileManager.default.fileExists(atPath: masterPath),
      let masterImage = NSImage(contentsOfFile: masterPath),
      let master = masterImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data(
        "找不到图标主图：\(masterPath)\n请先把 1024×1024 的圆角透明 PNG 放到该位置。\n".utf8
    ))
    exit(66)
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
    try renderIcon(
        pixelSize: pixelSize,
        master: master,
        outputURL: outputDirectory.appendingPathComponent(filename)
    )
}
