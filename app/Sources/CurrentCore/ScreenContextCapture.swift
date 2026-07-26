import AppKit
@preconcurrency import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit

public struct WindowContextDescriptor: Sendable, Equatable {
    public let windowIdentifier: UInt32
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let title: String?
    public let frame: ContextBounds
    public let isFrontmost: Bool

    public init(
        windowIdentifier: UInt32,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        title: String?,
        frame: ContextBounds,
        isFrontmost: Bool
    ) {
        self.windowIdentifier = windowIdentifier
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.frame = frame
        self.isFrontmost = isFrontmost
    }
}

public enum OCRWindowMapper {
    public static func observations(
        blocks: [ContextTextBlock],
        displayIdentifier: UInt32,
        displayFrame: ContextBounds,
        windows: [WindowContextDescriptor],
        capturedAt: Date
    ) -> [ContextObservation] {
        var grouped: [UInt32: [ContextTextBlock]] = [:]
        for block in blocks {
            guard let bounds = block.bounds else { continue }
            let centerX = displayFrame.x
                + (bounds.x + bounds.width / 2) * displayFrame.width
            let centerY = displayFrame.y
                + (1 - bounds.y - bounds.height / 2) * displayFrame.height
            let candidates = windows.filter {
                contains(x: centerX, y: centerY, in: $0.frame)
            }
            let owner = candidates.first(where: \.isFrontmost)
                ?? candidates.min { area($0.frame) < area($1.frame) }
            guard let owner else { continue }
            let screenBounds = ContextBounds(
                x: displayFrame.x + bounds.x * displayFrame.width,
                y: displayFrame.y
                    + (1 - bounds.y - bounds.height) * displayFrame.height,
                width: bounds.width * displayFrame.width,
                height: bounds.height * displayFrame.height
            )
            grouped[owner.windowIdentifier, default: []].append(
                ContextTextBlock(
                    id: block.id,
                    text: block.text,
                    source: block.source,
                    confidence: block.confidence,
                    bounds: screenBounds
                )
            )
        }
        return grouped.compactMap { windowIdentifier, groupedBlocks in
            guard let window = windows.first(where: {
                $0.windowIdentifier == windowIdentifier
            }) else {
                return nil
            }
            return ContextObservation(
                capturedAt: capturedAt,
                processIdentifier: window.processIdentifier,
                bundleIdentifier: window.bundleIdentifier,
                applicationName: window.applicationName,
                windowIdentifier: window.windowIdentifier,
                windowTitle: window.title,
                displayIdentifier: displayIdentifier,
                isFrontmost: window.isFrontmost,
                blocks: groupedBlocks
            )
        }
    }

    private static func contains(
        x: Double,
        y: Double,
        in bounds: ContextBounds
    ) -> Bool {
        x >= bounds.x
            && x <= bounds.x + bounds.width
            && y >= bounds.y
            && y <= bounds.y + bounds.height
    }

    private static func area(_ bounds: ContextBounds) -> Double {
        bounds.width * bounds.height
    }
}

public enum PerceptualImageHasher {
    public static func hash(_ image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        var result: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    result |= bit
                }
                bit <<= 1
            }
        }
        return result
    }

    public static func isVisuallyEquivalent(
        _ lhs: UInt64,
        _ rhs: UInt64,
        threshold: Int = 4
    ) -> Bool {
        (lhs ^ rhs).nonzeroBitCount <= threshold
    }
}
