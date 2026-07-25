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

    private struct UndoSnapshot {
        let processIdentifier: pid_t
        let createdAt: Date
    }

    private var target: Target?
    private var undoSnapshot: UndoSnapshot?
    public private(set) var targetApplicationPresentation: TargetApplicationPresentation?
    public private(set) var currentContext: DictationContext = .empty

    public init() {}

    public func captureTarget() {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPID {
            let applicationElement = AXUIElementCreateApplication(frontmostPID)
            // Chromium/Electron applications may not expose their complete
            // accessibility tree until an assistive client enables it.
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        }

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
        } else if let frontmostPID {
            let applicationElement = AXUIElementCreateApplication(frontmostPID)
            var applicationFocused: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &applicationFocused
            ) == .success,
               let applicationFocused {
                element = (applicationFocused as! AXUIElement)
            } else {
                element = nil
            }
        } else {
            element = nil
        }

        var elementPID: pid_t = 0
        let hasElementPID = element.map { AXUIElementGetPid($0, &elementPID) == .success } ?? false
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
        currentContext = Self.contextSnapshot(
            element: element,
            processIdentifier: processIdentifier,
            application: targetApplicationPresentation
        )
    }

    public func clearTarget() {
        target = nil
        targetApplicationPresentation = nil
        currentContext = .empty
    }

    public var contextCaptureTarget: ContextCaptureTarget? {
        guard let application = targetApplicationPresentation else { return nil }
        return ContextCaptureTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName,
            windowTitle: currentContext.windowTitle
        )
    }

    public static func frontmostContextCaptureTarget() -> ContextCaptureTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return ContextCaptureTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? "Application",
            windowTitle: focusedWindowTitle(
                processIdentifier: application.processIdentifier
            )
        )
    }

    public var canUndoLastInsertion: Bool {
        guard let undoSnapshot else { return false }
        return Date().timeIntervalSince(undoSnapshot.createdAt) < 5 * 60
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

    public func insert(
        _ rawText: String,
        context: DictationContext? = nil,
        trailingSpace: Bool? = nil,
        restoreClipboard: Bool = true
    ) async throws -> Result {
        let insertionContext = context ?? currentContext
        let text: String
        if let trailingSpace {
            text = Self.preparedText(rawText, trailingSpace: trailingSpace)
        } else {
            text = Self.preparedText(rawText, context: insertionContext)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if insertionContext.isEditingSelection, rawText.isEmpty {
                return try await deleteSelection(context: insertionContext)
            }
            throw CurrentError.insertionFailed("The transcription was empty.")
        }
        if target == nil { captureTarget() }
        let insertionTarget = target
        defer { clearTarget() }
        let pasteResult = await paste(
            text,
            into: target,
            restoreClipboard: restoreClipboard
        )
        let result: Result
        if pasteResult == .copied {
            result = insertWithAccessibility(text, element: target?.element) ? .inserted : .copied
        } else {
            result = pasteResult
        }
        if result != .copied, let processIdentifier = insertionTarget?.processIdentifier {
            undoSnapshot = UndoSnapshot(
                processIdentifier: processIdentifier,
                createdAt: Date()
            )
        }
        return result
    }

    nonisolated public static func preparedText(_ rawText: String, trailingSpace: Bool) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailingSpace, !trimmed.isEmpty, !trimmed.hasSuffix(" ") else { return trimmed }
        return trimmed + " "
    }

    nonisolated public static func preparedText(
        _ rawText: String,
        context: DictationContext
    ) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard !context.isEditingSelection else { return text }

        if let before = context.textBeforeCursor.last,
           !before.isWhitespace,
           !before.isNewline,
           let first = text.first,
           !first.isWhitespace,
           !",.;:!?)]}".contains(first) {
            text.insert(" ", at: text.startIndex)
        }

        if let after = context.textAfterCursor.first {
            if !after.isWhitespace,
               !after.isNewline,
               let last = text.last,
               !last.isWhitespace,
               !"([{\n".contains(last) {
                text.append(" ")
            }
        } else if context.destination != .message,
                  context.destination != .search,
                  context.destination != .codeOrTerminal,
                  let last = text.last,
                  last.isLetter || last.isNumber {
            text.append(" ")
        }
        return text
    }

    public func undoLastInsertion() async -> Bool {
        guard canUndoLastInsertion,
              let snapshot = undoSnapshot,
              let application = NSRunningApplication(
                  processIdentifier: snapshot.processIdentifier
              ),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 6,
                  keyDown: true
              ),
              let up = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 6,
                  keyDown: false
              ) else {
            undoSnapshot = nil
            return false
        }
        _ = application.activate(options: [])
        try? await Task.sleep(for: .milliseconds(60))
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(snapshot.processIdentifier)
        up.postToPid(snapshot.processIdentifier)
        undoSnapshot = nil
        return true
    }

    private func insertWithAccessibility(_ text: String, element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func deleteSelection(context: DictationContext) async throws -> Result {
        guard context.isEditingSelection else {
            throw CurrentError.insertionFailed("The transcription was empty.")
        }
        if target == nil { captureTarget() }
        let insertionTarget = target
        defer { clearTarget() }
        if insertWithAccessibility("", element: target?.element) {
            if let processIdentifier = insertionTarget?.processIdentifier {
                undoSnapshot = UndoSnapshot(
                    processIdentifier: processIdentifier,
                    createdAt: Date()
                )
            }
            return .inserted
        }
        throw CurrentError.insertionFailed("The selected text could not be deleted.")
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

        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return .copied
        }
        _ = application.activate(options: [])
        try? await Task.sleep(for: .milliseconds(80))

        if let element = target.element {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            try? await Task.sleep(for: .milliseconds(20))
        }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
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

    private nonisolated static func contextSnapshot(
        element: AXUIElement?,
        processIdentifier: pid_t?,
        application: TargetApplicationPresentation?
    ) -> DictationContext {
        guard let element else {
            return DictationContext(
                bundleIdentifier: application?.bundleIdentifier,
                applicationName: application?.localizedName,
                destination: destination(
                    bundleIdentifier: application?.bundleIdentifier,
                    applicationName: application?.localizedName,
                    role: nil,
                    subrole: nil,
                    description: nil
                )
            )
        }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let description = stringAttribute(kAXDescriptionAttribute, from: element)
            ?? stringAttribute(kAXHelpAttribute, from: element)
        let isSecure = isSecureField(
            role: role,
            subrole: subrole,
            description: description
        )

        let windowTitle = focusedWindowTitle(processIdentifier: processIdentifier)
        let destination = destination(
            bundleIdentifier: application?.bundleIdentifier,
            applicationName: application?.localizedName,
            role: role,
            subrole: subrole,
            description: description
        )
        guard !isSecure else {
            return DictationContext(
                bundleIdentifier: application?.bundleIdentifier,
                applicationName: application?.localizedName,
                windowTitle: windowTitle,
                focusedRole: role,
                focusedSubrole: subrole,
                destination: destination,
                isSecure: true
            )
        }

        let selectedText = stringAttribute(kAXSelectedTextAttribute, from: element)
        let value = stringAttribute(kAXValueAttribute, from: element) ?? ""
        let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute, from: element)
        let nearby = surroundingText(value: value, selectedRange: selectedRange)
        let isSearch = destination == .search
        let hasEditableSelection = !isSearch
            && (selectedText?.count ?? 0) <= DictationContext.maximumSelectionCharacters
            && !(selectedText?.isEmpty ?? true)
        let identifiers = extractedIdentifiers(
            from: [nearby.before, nearby.after, windowTitle ?? ""].joined(separator: " ")
        )

        return DictationContext(
            bundleIdentifier: application?.bundleIdentifier,
            applicationName: application?.localizedName,
            windowTitle: windowTitle,
            focusedRole: role,
            focusedSubrole: subrole,
            selectedText: hasEditableSelection ? selectedText : nil,
            textBeforeCursor: nearby.before,
            textAfterCursor: nearby.after,
            visibleIdentifiers: identifiers,
            destination: destination,
            isSecure: false,
            supportsSelectionEditing: hasEditableSelection
        )
    }

    nonisolated static func destination(
        bundleIdentifier: String?,
        applicationName: String?,
        role: String?,
        subrole: String?,
        description: String?
    ) -> DictationDestination {
        let identity = [
            bundleIdentifier,
            applicationName,
            role,
            subrole,
            description,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if identity.contains("search")
            || identity.contains("address field")
            || identity.contains("location field") {
            return .search
        }
        if [
            "terminal", "iterm", "warp", "xcode", "cursor", "windsurf",
            "visual studio code", "zed",
        ].contains(where: identity.contains) {
            return .codeOrTerminal
        }
        if [
            "messages", "slack", "discord", "whatsapp", "telegram", "signal",
            "teams", "wechat", "lark",
        ].contains(where: identity.contains) {
            return .message
        }
        if [
            "mail", "outlook", "gmail", "pages", "word", "notes", "notion",
            "google docs",
        ].contains(where: identity.contains) {
            return .emailOrDocument
        }
        return .generic
    }

    nonisolated static func isSecureField(
        role: String?,
        subrole: String?,
        description: String?
    ) -> Bool {
        role == "AXSecureTextField"
            || subrole?.localizedCaseInsensitiveContains("secure") == true
            || description?.localizedCaseInsensitiveContains("password") == true
    }

    private nonisolated static func stringAttribute(
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

    private nonisolated static func rangeAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private nonisolated static func surroundingText(
        value: String,
        selectedRange: CFRange?
    ) -> (before: String, after: String) {
        guard let selectedRange,
              selectedRange.location >= 0,
              selectedRange.length >= 0 else {
            return ("", "")
        }
        let utf16 = value.utf16
        let location = min(selectedRange.location, utf16.count)
        let end = min(location + selectedRange.length, utf16.count)
        let startIndex = String.Index(utf16Offset: location, in: value)
        let endIndex = String.Index(utf16Offset: end, in: value)
        return (
            String(value[..<startIndex].suffix(DictationContext.maximumNearbyCharacters / 2)),
            String(value[endIndex...].prefix(DictationContext.maximumNearbyCharacters / 2))
        )
    }

    private nonisolated static func focusedWindowTitle(
        processIdentifier: pid_t?
    ) -> String? {
        guard let processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue else { return nil }
        return stringAttribute(
            kAXTitleAttribute,
            from: windowValue as! AXUIElement
        )
    }

    private nonisolated static func extractedIdentifiers(from text: String) -> [String] {
        let patterns = [
            #"\b[A-Za-z][A-Za-z0-9_-]*\.(?:swift|ts|tsx|js|jsx|py|go|rs|json|md|ya?ml)\b"#,
            #"\b[A-Z]{2,8}\b"#,
            #"\b[a-z]+(?:[A-Z][A-Za-z0-9]*)+\b"#,
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let range = Range(match.range, in: text) else { continue }
                let value = String(text[range])
                if !values.contains(value) { values.append(value) }
            }
        }
        return Array(values.prefix(80))
    }
}
