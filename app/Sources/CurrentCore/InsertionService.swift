import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class InsertionService {
    public enum Result: Sendable, Equatable { case inserted, pasted, copied }

    public struct TargetApplicationPresentation {
        public let processIdentifier: pid_t
        public let bundleIdentifier: String?
        public let localizedName: String
        public let icon: NSImage?

        public init(
            processIdentifier: pid_t,
            bundleIdentifier: String?,
            localizedName: String,
            icon: NSImage?
        ) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.localizedName = localizedName
            self.icon = icon
        }
    }

    private struct Target {
        let element: AXUIElement?
        let processIdentifier: pid_t?
    }

    private var target: Target?
    public private(set) var targetApplicationPresentation: TargetApplicationPresentation?

    public init() {}

    public func captureTarget() {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let element: AXUIElement?
        if AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
           let focused {
            element = (focused as! AXUIElement)
        } else {
            element = nil
        }

        var elementPID: pid_t = 0
        let hasElementPID = element.map { AXUIElementGetPid($0, &elementPID) == .success } ?? false
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let processIdentifier = Self.eventProcessIdentifier(
            frontmost: frontmostPID,
            accessibilityElement: hasElementPID ? elementPID : nil
        )
        target = Target(
            element: element,
            processIdentifier: processIdentifier
        )
        targetApplicationPresentation = Self.applicationPresentation(
            processIdentifier: processIdentifier
        )
    }

    public func clearTarget() {
        target = nil
        targetApplicationPresentation = nil
    }

    nonisolated static func eventProcessIdentifier(
        frontmost: pid_t?,
        accessibilityElement: pid_t?
    ) -> pid_t? {
        // Safari exposes website controls from a WebKit content process, but
        // keyboard events must be delivered to the frontmost browser process.
        frontmost ?? accessibilityElement
    }

    static func applicationPresentation(
        processIdentifier: pid_t?
    ) -> TargetApplicationPresentation? {
        guard let processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }
        return TargetApplicationPresentation(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName ?? "Application",
            icon: application.icon?.copy() as? NSImage
        )
    }

    public func insert(_ rawText: String, trailingSpace: Bool, restoreClipboard: Bool) async throws -> Result {
        let text = Self.preparedText(rawText, trailingSpace: trailingSpace)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CurrentError.insertionFailed("The transcription was empty.")
        }
        if target == nil { captureTarget() }
        defer { clearTarget() }
        if insertWithAccessibility(text, element: target?.element) { return .inserted }
        return await paste(
            text,
            into: target,
            restoreClipboard: restoreClipboard
        )
    }

    nonisolated public static func preparedText(_ rawText: String, trailingSpace: Bool) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailingSpace, !trimmed.isEmpty, !trimmed.hasSuffix(" ") else { return trimmed }
        return trimmed + " "
    }

    private func insertWithAccessibility(_ text: String, element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func paste(_ text: String, into target: Target?, restoreClipboard: Bool) async -> Result {
        let pasteboard = NSPasteboard.general
        let previous = restoreClipboard ? pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        } : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard AXIsProcessTrusted(),
              let target,
              let processIdentifier = target.processIdentifier,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .copied }

        if let element = target.element {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return .copied
        }
        _ = application.activate(options: [])
        try? await Task.sleep(for: .milliseconds(80))

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if let previous {
            try? await Task.sleep(for: .milliseconds(450))
            pasteboard.clearContents()
            let restored = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        return .pasted
    }
}
