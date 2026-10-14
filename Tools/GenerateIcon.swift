import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift GenerateIcon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
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

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let scale = CGFloat(size)
    let outer = NSRect(x: scale * 0.055, y: scale * 0.055, width: scale * 0.89, height: scale * 0.89)
    let outerPath = NSBezierPath(roundedRect: outer, xRadius: scale * 0.21, yRadius: scale * 0.21)
    NSGradient(
        starting: NSColor(red: 0.055, green: 0.20, blue: 0.29, alpha: 1),
        ending: NSColor(red: 0.03, green: 0.48, blue: 0.47, alpha: 1)
    )!.draw(in: outerPath, angle: -48)

    let glow = NSBezierPath(ovalIn: NSRect(x: scale * 0.49, y: scale * 0.47, width: scale * 0.37, height: scale * 0.37))
    NSColor.systemOrange.withAlphaComponent(0.22).setFill()
    glow.fill()

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: scale * 0.50, y: scale * 0.82))
    shield.curve(to: NSPoint(x: scale * 0.24, y: scale * 0.68), controlPoint1: NSPoint(x: scale * 0.40, y: scale * 0.77), controlPoint2: NSPoint(x: scale * 0.31, y: scale * 0.72))
    shield.line(to: NSPoint(x: scale * 0.27, y: scale * 0.40))
    shield.curve(to: NSPoint(x: scale * 0.50, y: scale * 0.18), controlPoint1: NSPoint(x: scale * 0.29, y: scale * 0.30), controlPoint2: NSPoint(x: scale * 0.39, y: scale * 0.21))
    shield.curve(to: NSPoint(x: scale * 0.73, y: scale * 0.40), controlPoint1: NSPoint(x: scale * 0.61, y: scale * 0.21), controlPoint2: NSPoint(x: scale * 0.71, y: scale * 0.30))
    shield.line(to: NSPoint(x: scale * 0.76, y: scale * 0.68))
    shield.curve(to: NSPoint(x: scale * 0.50, y: scale * 0.82), controlPoint1: NSPoint(x: scale * 0.69, y: scale * 0.72), controlPoint2: NSPoint(x: scale * 0.60, y: scale * 0.77))
    shield.close()
    NSColor.white.withAlphaComponent(0.96).setStroke()
    shield.lineWidth = max(1.4, scale * 0.035)
    shield.lineJoinStyle = .round
    shield.stroke()

    let tube = NSBezierPath(roundedRect: NSRect(x: scale * 0.455, y: scale * 0.39, width: scale * 0.09, height: scale * 0.27), xRadius: scale * 0.045, yRadius: scale * 0.045)
    NSColor.white.withAlphaComponent(0.98).setFill()
    tube.fill()
    let bulb = NSBezierPath(ovalIn: NSRect(x: scale * 0.40, y: scale * 0.28, width: scale * 0.20, height: scale * 0.20))
    NSColor.white.withAlphaComponent(0.98).setFill()
    bulb.fill()
    let heat = NSBezierPath(roundedRect: NSRect(x: scale * 0.48, y: scale * 0.40, width: scale * 0.04, height: scale * 0.16), xRadius: scale * 0.02, yRadius: scale * 0.02)
    NSColor.systemOrange.setFill()
    heat.fill()
    let heatBulb = NSBezierPath(ovalIn: NSRect(x: scale * 0.445, y: scale * 0.325, width: scale * 0.11, height: scale * 0.11))
    heatBulb.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for (name, size) in variants {
    try render(size: size).write(to: destination.appendingPathComponent(name), options: .atomic)
}
