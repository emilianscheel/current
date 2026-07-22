import CoreGraphics
import Foundation

public enum OverlayAttachment: Sendable, Equatable {
    case notch
    case detached
}

public struct OverlayLayout: Sendable, Equatable {
    public let attachment: OverlayAttachment
    public let panelFrame: CGRect
    public let collapsedSize: CGSize
    public let expandedSize: CGSize
    public let topPadding: CGFloat

    public init(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        notchBounds: CGRect?
    ) {
        let hasNotch = safeAreaTop > 0 && (notchBounds?.width ?? 0) > 40
        if hasNotch, let notchBounds {
            attachment = .notch
            collapsedSize = CGSize(width: notchBounds.width, height: max(safeAreaTop, notchBounds.height))
            expandedSize = CGSize(
                width: min(max(notchBounds.width + 340, 520), screenFrame.width * 0.68),
                height: max(safeAreaTop + 36, 64)
            )
            topPadding = 0
        } else {
            attachment = .detached
            collapsedSize = CGSize(width: 92, height: 10)
            expandedSize = CGSize(width: min(260, screenFrame.width - 40), height: 54)
            topPadding = 8
        }

        let panelHeight = expandedSize.height + topPadding
        panelFrame = CGRect(
            x: screenFrame.midX - expandedSize.width / 2,
            y: screenFrame.maxY - panelHeight,
            width: expandedSize.width,
            height: panelHeight
        )
    }
}
