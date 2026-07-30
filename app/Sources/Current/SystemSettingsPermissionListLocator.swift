@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum SystemSettingsPermissionListLocator {
    private struct Candidate {
        let frame: CGRect
        let score: CGFloat
    }

    static func listFrame(
        processIdentifier: pid_t,
        settingsFrame: CGRect,
        convertToAppKit: (CGRect) -> CGRect?
    ) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let application = AXUIElementCreateApplication(processIdentifier)
        var queue = [application]
        var index = 0
        var visited = 0
        var candidates: [Candidate] = []

        while index < queue.count, visited < 500 {
            let element = queue[index]
            index += 1
            visited += 1

            if let role = stringAttribute(kAXRoleAttribute, from: element),
               let roleWeight = roleWeight(role),
               let accessibilityFrame = frame(of: element),
               let appKitFrame = convertToAppKit(accessibilityFrame),
               isPlausible(appKitFrame, inside: settingsFrame) {
                let area = appKitFrame.width * appKitFrame.height
                let alignmentPenalty = abs(
                    appKitFrame.minX - (settingsFrame.minX + 244)
                ) + abs(
                    appKitFrame.maxY - (settingsFrame.maxY - 112)
                )
                candidates.append(
                    Candidate(
                        frame: appKitFrame,
                        score: roleWeight + area / 1_000 - alignmentPenalty
                    )
                )
            }

            queue.append(contentsOf: elementsAttribute(
                kAXChildrenAttribute,
                from: element
            ))
        }

        return candidates.max(by: { $0.score < $1.score })?.frame
    }

    private static func roleWeight(_ role: String) -> CGFloat? {
        switch role {
        case "AXTable": 4_000
        case "AXOutline": 3_500
        case "AXList": 3_000
        case "AXScrollArea": 2_000
        default: nil
        }
    }

    private static func isPlausible(
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

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func pointAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func elementsAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
