#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

private let canvas = NSSize(width: 1024, height: 1024)
private let faceRect = NSRect(x: 72, y: 72, width: 880, height: 880)

func masterImage() throws -> NSImage {
    let image = NSImage(size: canvas)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvas).fill()

    let face = NSBezierPath(roundedRect: faceRect, xRadius: 205, yRadius: 205)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    face.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    NSGradient(colorsAndLocations:
        (NSColor(calibratedWhite: 1.0, alpha: 1), 0),
        (NSColor(calibratedWhite: 0.985, alpha: 1), 0.48),
        (NSColor(calibratedWhite: 0.89, alpha: 1), 1)
    )!.draw(in: faceRect, angle: -90)

    let upperHighlight = NSBezierPath(ovalIn: NSRect(x: -80, y: 485, width: 1184, height: 690))
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.48), 0),
        (NSColor.white.withAlphaComponent(0.12), 0.58),
        (NSColor.white.withAlphaComponent(0), 1)
    )!.draw(in: upperHighlight, relativeCenterPosition: .zero)

    let lowerShade = NSBezierPath(ovalIn: NSRect(x: 70, y: -225, width: 884, height: 490))
    NSColor.black.withAlphaComponent(0.035).setFill()
    lowerShade.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.1).setStroke()
    face.lineWidth = 3
    face.stroke()

    guard let symbol = NSImage(systemSymbolName: "alternatingcurrent", accessibilityDescription: nil)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        ) else {
        throw CocoaError(.featureUnsupported)
    }
    let symbolBounds = NSRect(x: 237, y: 307, width: 550, height: 410)
    symbol.draw(in: symbolBounds, from: .zero, operation: .sourceOver, fraction: 1)

    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: 225, y: 805))
    gloss.curve(
        to: NSPoint(x: 799, y: 805),
        controlPoint1: NSPoint(x: 380, y: 876),
        controlPoint2: NSPoint(x: 644, y: 876)
    )
    gloss.lineCapStyle = .round
    gloss.lineWidth = 8
    NSColor.white.withAlphaComponent(0.44).setStroke()
    gloss.stroke()

    return image
}

func png(_ image: NSImage, pixels: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(origin: .zero, size: canvas),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: output.appendingPathComponent(name))
}

let image = try masterImage()
for size in [16, 32, 128, 256, 512] {
    try png(image, pixels: size, name: "icon_\(size)x\(size).png")
    try png(image, pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
print(output.path)
