import CoreGraphics
import Foundation

package enum PermissionGuidanceMotion {
    package static let duration: TimeInterval = 0.14

    package static func easedProgress(_ progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    package static func interpolate(
        from start: CGRect,
        to end: CGRect,
        progress: CGFloat
    ) -> CGRect {
        let eased = easedProgress(progress)
        return CGRect(
            x: start.minX + (end.minX - start.minX) * eased,
            y: start.minY + (end.minY - start.minY) * eased,
            width: start.width + (end.width - start.width) * eased,
            height: start.height + (end.height - start.height) * eased
        )
    }
}

package struct PermissionGuidanceLayout: Equatable, Sendable {
    package enum Placement: Equatable, Sendable {
        case detected
        case conservative
    }

    package let listFrame: CGRect
    package let guideFrame: CGRect
    package let placement: Placement

    package init(
        settingsFrame: CGRect,
        detectedListFrame: CGRect? = nil
    ) {
        let leadingInset: CGFloat = 244
        let trailingInset: CGFloat = 20
        let topInset: CGFloat = 112
        let guideBottomInset: CGFloat = 78
        let guideHeight: CGFloat = 168
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

        if let detectedListFrame,
           Self.isValidDetectedListFrame(
               detectedListFrame,
               inside: settingsFrame
           ) {
            placement = .detected
            listFrame = detectedListFrame
            guideFrame = CGRect(
                x: detectedListFrame.minX,
                y: detectedListFrame.minY - gap - guideHeight,
                width: detectedListFrame.width,
                height: guideHeight
            )
            return
        }

        let conservativeGuideFrame = CGRect(
            x: detailX,
            y: settingsFrame.minY + guideBottomInset,
            width: detailWidth,
            height: guideHeight
        )
        let listTop = settingsFrame.maxY - topInset
        let listBottom = conservativeGuideFrame.maxY + gap

        placement = .conservative
        listFrame = CGRect(
            x: detailX,
            y: listBottom,
            width: detailWidth,
            height: max(0, listTop - listBottom)
        )
        guideFrame = conservativeGuideFrame
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

    package static func translatedDetectedListFrame(
        _ listFrame: CGRect,
        from previousSettingsFrame: CGRect,
        to settingsFrame: CGRect
    ) -> CGRect? {
        guard previousSettingsFrame.size == settingsFrame.size else {
            return nil
        }
        return listFrame.offsetBy(
            dx: settingsFrame.minX - previousSettingsFrame.minX,
            dy: settingsFrame.minY - previousSettingsFrame.minY
        )
    }

    private static func isValidDetectedListFrame(
        _ frame: CGRect,
        inside settingsFrame: CGRect
    ) -> Bool {
        guard frame.width >= 320,
              frame.height >= 160,
              frame.minX >= settingsFrame.minX + 180,
              frame.maxX <= settingsFrame.maxX + 4,
              frame.minY >= settingsFrame.minY - 4,
              frame.maxY <= settingsFrame.maxY - 56 else {
            return false
        }

        let intersection = frame.intersection(settingsFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        return intersection.width * intersection.height
            >= frame.width * frame.height * 0.95
    }
}
