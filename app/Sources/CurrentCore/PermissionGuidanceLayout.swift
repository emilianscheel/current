import CoreGraphics

package struct PermissionGuidanceLayout: Equatable, Sendable {
    package enum Placement: Equatable, Sendable {
        case belowWindow
    }

    package let listFrame: CGRect
    package let guideFrame: CGRect
    package let placement: Placement

    package init(settingsFrame: CGRect) {
        let leadingInset: CGFloat = 244
        let trailingInset: CGFloat = 20
        let topInset: CGFloat = 112
        let bottomInset: CGFloat = 2
        let guideHeight: CGFloat = 124
        let gap: CGFloat = 8
        let minimumDetailWidth: CGFloat = 320

        let detailX = min(
            settingsFrame.minX + leadingInset,
            settingsFrame.maxX - trailingInset - minimumDetailWidth
        )
        let detailWidth = max(
            minimumDetailWidth,
            settingsFrame.maxX - trailingInset - detailX
        )
        let listTop = settingsFrame.maxY - topInset
        let listBottom = settingsFrame.minY + bottomInset

        placement = .belowWindow
        listFrame = CGRect(
            x: detailX,
            y: listBottom,
            width: detailWidth,
            height: max(0, listTop - listBottom)
        )
        guideFrame = CGRect(
            x: detailX,
            y: listFrame.minY - gap - guideHeight,
            width: detailWidth,
            height: guideHeight
        )
    }

    package static func localIntersection(
        of frame: CGRect,
        in screenFrame: CGRect
    ) -> CGRect? {
        let intersection = frame.intersection(screenFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return intersection.offsetBy(
            dx: -screenFrame.minX,
            dy: -screenFrame.minY
        )
    }
}
