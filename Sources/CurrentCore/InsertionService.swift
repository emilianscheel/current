import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class InsertionService {
    public enum Result: Sendable, Equatable { case inserted, pasted, copied }

    public init() {}

    public func insert(_ rawText: String, trailingSpace: Bool, restoreClipboard: Bool) async throws -> Result {
        let text = Self.preparedText(rawText, trailingSpace: trailingSpace)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CurrentError.insertionFailed("The transcription was empty.")
        }
        if insertWithAccessibility(text) { return .inserted }
        return await paste(text, restoreClipboard: restoreClipboard)
    }

    nonisolated public static func preparedText(_ rawText: String, trailingSpace: Bool) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailingSpace, !trimmed.isEmpty, !trimmed.hasSuffix(" ") else { return trimmed }
        return trimmed + " "
    }

    private func insertWithAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func paste(_ text: String, restoreClipboard: Bool) async -> Result {
        let pasteboard = NSPasteboard.general
        let previous = restoreClipboard ? pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        } : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .copied }
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
