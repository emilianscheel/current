import CoreGraphics
import Foundation

public enum ShortcutEvent: Sendable, Equatable {
    case armed, pressed, released, cancelled
}

public struct ShortcutStateMachine: Sendable {
    public private(set) var fnIsDown = false
    public private(set) var isRecording = false
    public private(set) var isChorded = false

    public init() {}

    public mutating func fnChanged(isDown: Bool) -> ShortcutEvent? {
        if isDown {
            guard !fnIsDown else { return nil }
            fnIsDown = true
            isChorded = false
            return .armed
        }
        guard fnIsDown else { return nil }
        fnIsDown = false
        defer { isRecording = false; isChorded = false }
        if isChorded { return isRecording ? .cancelled : nil }
        return isRecording ? .released : .cancelled
    }

    public mutating func otherKeyPressed() -> ShortcutEvent? {
        guard fnIsDown else { return nil }
        isChorded = true
        if isRecording {
            isRecording = false
            return .cancelled
        }
        return nil
    }

    public mutating func thresholdReached() -> ShortcutEvent? {
        guard fnIsDown, !isChorded, !isRecording else { return nil }
        isRecording = true
        return .pressed
    }

    public mutating func escape() -> ShortcutEvent? {
        guard isRecording else { return nil }
        isRecording = false
        isChorded = true
        return .cancelled
    }
}

public final class ShortcutMonitor: @unchecked Sendable {
    public var onEvent: (@Sendable (ShortcutEvent) -> Void)?
    public var holdThreshold: Duration = .milliseconds(180)
    public var fallbackPreset = "control-option-space"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var state = ShortcutStateMachine()
    private var thresholdTask: Task<Void, Never>?
    private var fallbackIsDown = false

    public init() {}

    public func start() throws {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(pointer).takeUnretainedValue()
                return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            throw CurrentError.permissionMissing(.inputMonitoring)
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        thresholdTask?.cancel()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        lock.withLock { state = ShortcutStateMachine(); fallbackIsDown = false }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, keyCode == 49, matchesFallback(event.flags) {
            let shouldStart = lock.withLock { () -> Bool in
                guard !fallbackIsDown else { return false }
                fallbackIsDown = true
                return true
            }
            if shouldStart { emit(.pressed) }
            return true
        }
        if type == .keyUp, keyCode == 49, lock.withLock({ fallbackIsDown }) {
            lock.withLock { fallbackIsDown = false }
            emit(.released)
            return true
        }
        if type == .flagsChanged {
            let down = event.flags.contains(.maskSecondaryFn)
            let action = lock.withLock { state.fnChanged(isDown: down) }
            if action == .armed { scheduleThreshold() }
            if !down { thresholdTask?.cancel() }
            emit(action)
        } else if type == .keyDown {
            if keyCode == 53 {
                emit(lock.withLock { state.escape() })
            } else {
                thresholdTask?.cancel()
                emit(lock.withLock { state.otherKeyPressed() })
            }
        }
        return false
    }

    private func matchesFallback(_ flags: CGEventFlags) -> Bool {
        switch fallbackPreset {
        case "control-option-space": flags.contains(.maskControl) && flags.contains(.maskAlternate)
        case "command-shift-space": flags.contains(.maskCommand) && flags.contains(.maskShift)
        default: false
        }
    }

    private func scheduleThreshold() {
        thresholdTask?.cancel()
        thresholdTask = Task { [weak self, holdThreshold] in
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, let self else { return }
            emit(lock.withLock { state.thresholdReached() })
        }
    }

    private func emit(_ event: ShortcutEvent?) {
        guard let event else { return }
        onEvent?(event)
    }
}
