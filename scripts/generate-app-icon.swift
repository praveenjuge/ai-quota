#!/usr/bin/env swift
import AppKit

// Canonical artwork, rendered at each native icon size without external tools.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "AppIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.86, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.29, blue: 0.79, alpha: 1),
        NSColor(calibratedRed: 0.23, green: 0.57, blue: 1, alpha: 1)
    ])!.draw(in: tile, angle: 90)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Open ring conveys remaining capacity; the needle makes the gauge distinct.
    let track = NSBezierPath()
    track.appendArc(withCenter: NSPoint(x: 512, y: 506), radius: 267, startAngle: 225, endAngle: -45, clockwise: true)
    track.lineWidth = 72
    track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.24).setStroke()
    track.stroke()
    let remaining = NSBezierPath()
    remaining.appendArc(withCenter: NSPoint(x: 512, y: 506), radius: 267, startAngle: 225, endAngle: 28, clockwise: true)
    remaining.lineWidth = 72
    remaining.lineCapStyle = .round
    NSColor.white.setStroke()
    remaining.stroke()
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: 512, y: 506))
    needle.line(to: NSPoint(x: 654, y: 642))
    needle.lineWidth = 54
    needle.lineCapStyle = .round
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 462, y: 456, width: 100, height: 100)).fill()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2)
    }
    return png
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: base * scale).write(to: output.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
