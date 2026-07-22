#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func masterImage() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.38, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.03, green: 0.12, blue: 0.16, alpha: 1)])!.draw(in: rect, angle: -52)

    let main = NSBezierPath()
    main.move(to: NSPoint(x: 170, y: 489))
    main.curve(to: NSPoint(x: 350, y: 694), controlPoint1: NSPoint(x: 245, y: 489), controlPoint2: NSPoint(x: 250, y: 694))
    main.curve(to: NSPoint(x: 558, y: 328), controlPoint1: NSPoint(x: 452, y: 694), controlPoint2: NSPoint(x: 456, y: 328))
    main.curve(to: NSPoint(x: 854, y: 549), controlPoint1: NSPoint(x: 657, y: 328), controlPoint2: NSPoint(x: 666, y: 549))
    main.lineCapStyle = .round
    main.lineWidth = 112
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 1, alpha: 0.12).setStroke(); main.stroke()
    main.lineWidth = 68
    NSGradient(colors: [NSColor(calibratedRed: 0.69, green: 0.65, blue: 1, alpha: 1), NSColor(calibratedRed: 0.35, green: 0.85, blue: 1, alpha: 1), NSColor(calibratedRed: 0.38, green: 1, blue: 0.82, alpha: 1)])!.draw(in: main, angle: -20)

    let secondary = NSBezierPath()
    secondary.move(to: NSPoint(x: 178, y: 359))
    secondary.curve(to: NSPoint(x: 397, y: 559), controlPoint1: NSPoint(x: 287, y: 359), controlPoint2: NSPoint(x: 295, y: 559))
    secondary.curve(to: NSPoint(x: 611, y: 434), controlPoint1: NSPoint(x: 500, y: 559), controlPoint2: NSPoint(x: 505, y: 434))
    secondary.curve(to: NSPoint(x: 846, y: 664), controlPoint1: NSPoint(x: 715, y: 434), controlPoint2: NSPoint(x: 728, y: 664))
    secondary.lineCapStyle = .round; secondary.lineWidth = 20
    NSColor(calibratedWhite: 0.96, alpha: 0.22).setStroke(); secondary.stroke()
    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: NSRect(x: 0, y: 0, width: 1024, height: 1024), operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output.appendingPathComponent(name))
}

let image = masterImage()
for size in [16, 32, 128, 256, 512] {
    try png(image, pixels: size, name: "icon_\(size)x\(size).png")
    try png(image, pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
print(output.path)
