#!/usr/bin/env swift
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: render-app-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("failed to create bitmap rep\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext

let cornerRadius: CGFloat = 230
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

let bgColors = [
    CGColor(srgbRed: 0.36, green: 0.66, blue: 1.00, alpha: 1.0),
    CGColor(srgbRed: 0.04, green: 0.13, blue: 0.45, alpha: 1.0),
] as CFArray
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

let hlColors = [
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray
let hl = CGGradient(colorsSpace: colorSpace, colors: hlColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    hl,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: size * 0.55),
    options: []
)

ctx.restoreGState()

NSColor.white.setFill()
NSColor.white.setStroke()

let bodyW: CGFloat = 240
let bodyH: CGFloat = 460
let bodyRect = CGRect(x: (size - bodyW) / 2, y: 350, width: bodyW, height: bodyH)
NSBezierPath(roundedRect: bodyRect, xRadius: bodyW / 2, yRadius: bodyW / 2).fill()

let cradlePath = NSBezierPath()
cradlePath.appendArc(
    withCenter: NSPoint(x: size / 2, y: 590),
    radius: 240,
    startAngle: 180,
    endAngle: 360
)
cradlePath.lineWidth = 50
cradlePath.lineCapStyle = .round
cradlePath.stroke()

let stemRect = CGRect(x: size / 2 - 16, y: 275, width: 32, height: 50)
NSBezierPath(roundedRect: stemRect, xRadius: 4, yRadius: 4).fill()

let baseRect = CGRect(x: size / 2 - 140, y: 235, width: 280, height: 40)
NSBezierPath(roundedRect: baseRect, xRadius: 20, yRadius: 20).fill()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
