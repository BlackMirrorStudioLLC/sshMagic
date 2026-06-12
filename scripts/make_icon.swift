#!/usr/bin/env swift
//
// Generates sshMagic's app icon: a dark squircle with a glowing electric-blue
// terminal prompt ">_" and a magic sparkle. Renders every macOS iconset size
// natively (crisp at 16px through 1024px) and runs `iconutil` to produce
// Resources/AppIcon.icns.
//
// Usage:  swift scripts/make_icon.swift
//
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Colors (sRGB)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: A 4-point "magic" sparkle

func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let inner = radius * 0.30
    var points: [CGPoint] = []
    for i in 0..<8 {
        let r = (i % 2 == 0) ? radius : inner
        let angle = (Double(i) * 45.0 + 90.0) * .pi / 180.0
        points.append(CGPoint(x: center.x + CGFloat(cos(angle)) * r,
                              y: center.y + CGFloat(sin(angle)) * r))
    }
    path.move(to: points[0])
    points.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
}

// MARK: Draw the whole icon at pixel size S

func draw(_ ctx: CGContext, _ size: Int) {
    let S = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    let margin = S * 0.075
    let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = rect.width * 0.2237  // the macOS "squircle" corner ratio
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 1. Base fill with a soft drop shadow so the tile floats.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.045,
                  color: rgb(0, 0, 0, 0.55))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0.05, 0.06, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Background gradient + accent glow, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [rgb(0.13, 0.17, 0.30), rgb(0.04, 0.05, 0.09)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    let glow = CGGradient(colorsSpace: cs,
                          colors: [rgb(0.28, 0.6, 1.0, 0.55), rgb(0.28, 0.6, 1.0, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S * 0.46, y: S * 0.47), startRadius: 0,
                           endCenter: CGPoint(x: S * 0.46, y: S * 0.47), endRadius: S * 0.43,
                           options: [])
    ctx.restoreGState()

    // 3. Faint top edge highlight for depth.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(S * 0.004)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.strokePath()
    ctx.restoreGState()

    // 4. The ">_" terminal prompt.
    let glyph = CGMutablePath()
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: S * 0.31, y: S * 0.585))
    chevron.addLine(to: CGPoint(x: S * 0.515, y: S * 0.45))
    chevron.addLine(to: CGPoint(x: S * 0.31, y: S * 0.315))
    glyph.addPath(chevron.copy(strokingWithWidth: S * 0.072, lineCap: .round,
                               lineJoin: .round, miterLimit: 10))
    glyph.addPath(CGPath(roundedRect: CGRect(x: S * 0.55, y: S * 0.30, width: S * 0.165, height: S * 0.052),
                         cornerWidth: S * 0.026, cornerHeight: S * 0.026, transform: nil))

    // Glow behind the glyph.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.05, color: rgb(0.3, 0.7, 1.0, 0.9))
    ctx.addPath(glyph)
    ctx.setFillColor(rgb(0.35, 0.75, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill of the glyph.
    ctx.saveGState()
    ctx.addPath(glyph)
    ctx.clip()
    let glyphGrad = CGGradient(colorsSpace: cs,
                               colors: [rgb(0.55, 0.93, 1.0), rgb(0.30, 0.58, 1.0)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(glyphGrad, start: CGPoint(x: 0, y: S * 0.6),
                           end: CGPoint(x: 0, y: S * 0.28), options: [])
    ctx.restoreGState()

    // 5. The magic sparkle, upper-right of the chevron.
    let spark = sparklePath(center: CGPoint(x: S * 0.63, y: S * 0.655), radius: S * 0.085)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.03, color: rgb(0.7, 0.9, 1.0, 0.95))
    ctx.addPath(spark)
    ctx.setFillColor(rgb(0.92, 0.97, 1.0))
    ctx.fillPath()
    ctx.restoreGState()
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, pixels)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

// MARK: Build the iconset and run iconutil

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (filename, pixel size)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var cache: [Int: CGImage] = [:]
for (name, px) in entries {
    let image = cache[px] ?? render(px)
    cache[px] = image
    writePNG(image, to: iconset.appendingPathComponent(name))
}
// Also drop a standalone 1024 preview.
writePNG(cache[1024] ?? render(1024), to: resources.appendingPathComponent("AppIcon-preview.png"))

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path,
                  "-o", resources.appendingPathComponent("AppIcon.icns").path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)  // keep only the .icns + preview

print(proc.terminationStatus == 0
    ? "Wrote \(resources.appendingPathComponent("AppIcon.icns").path)"
    : "iconutil failed (\(proc.terminationStatus))")
exit(proc.terminationStatus)
