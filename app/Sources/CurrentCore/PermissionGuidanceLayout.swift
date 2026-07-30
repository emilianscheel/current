import CoreGraphics

package struct PermissionGuidanceLayout: Equatable, Sendable {
    package enum Placement: Equatable, Sendable {
        case embedded
        case belowWindow
    }

    package let listFrame: CGRect
    package let guideFrame: CGRect
    package let placement: Placement

    package init(settingsFrame: CGRect) {
        let leadingInset: CGFloat = 244
        let trailingInset: CGFloat = 20
        let topInset: CGFloat = 112
        let guideHeight: CGFloat = 172
        let guideBottomInset: CGFloat = 78
        let gap: CGFloat = 8
        let minimumListHeight: CGFloat = 160
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
        let embeddedGuide = CGRect(
            x: detailX,
            y: settingsFrame.minY + guideBottomInset,
            width: detailWidth,
            height: guideHeight
        )
        let embeddedListBottom = embeddedGuide.maxY + gap

        if listTop - embeddedListBottom >= minimumListHeight {
            placement = .embedded
            guideFrame = embeddedGuide
            listFrame = CGRect(
                x: detailX,
                y: embeddedListBottom,
                width: detailWidth,
                height: listTop - embeddedListBottom
            )
        } else {
            placement = .belowWindow
            guideFrame = CGRect(
                x: detailX,
                y: settingsFrame.minY - guideHeight - gap,
                width: detailWidth,
                height: guideHeight
            )
            let listBottom = settingsFrame.minY + 20
            listFrame = CGRect(
                x: detailX,
                y: listBottom,
                width: detailWidth,
                height: max(minimumListHeight, listTop - listBottom)
            )
        }
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
