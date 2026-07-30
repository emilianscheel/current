import Foundation

public enum OverlayPresentationState: Sendable, Equatable {
    case hidden
    case presenting
    case visible
    case dismissing
}

public struct OverlayAnimationPolicy: Sendable, Equatable {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    public var animatesShape: Bool { !reduceMotion }
    public var presentationContentDuration: TimeInterval { reduceMotion ? 0.12 : 0.18 }
    public var dismissalContentDuration: TimeInterval { 0.12 }
}

public enum OverlayPresentationCommand: Sendable, Equatable {
    case present(generation: UInt64)
    case dismiss(generation: UInt64)
}

public struct OverlayPresentationMachine: Sendable, Equatable {
    public private(set) var state: OverlayPresentationState = .hidden
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func requestVisible(_ visible: Bool) -> OverlayPresentationCommand? {
        if visible {
            guard state == .hidden || state == .dismissing else { return nil }
            generation &+= 1
            state = .presenting
            return .present(generation: generation)
        }

        guard state == .presenting || state == .visible else { return nil }
        generation &+= 1
        state = .dismissing
        return .dismiss(generation: generation)
    }

    @discardableResult
    public mutating func completePresentation(generation completedGeneration: UInt64) -> Bool {
        guard state == .presenting, generation == completedGeneration else { return false }
        state = .visible
        return true
    }

    @discardableResult
    public mutating func completeDismissal(generation completedGeneration: UInt64) -> Bool {
        guard state == .dismissing, generation == completedGeneration else { return false }
        state = .hidden
        return true
    }
}

public struct WaveformLevelSmoother: Sendable, Equatable {
    public private(set) var value: Float

    public init(value: Float = 0) {
        self.value = min(1, max(0, value))
    }

    @discardableResult
    public mutating func update(target: Float, deltaTime: TimeInterval) -> Float {
        let clampedTarget = min(1, max(0, target.isFinite ? target : 0))
        let clampedDelta = min(0.1, max(0, deltaTime))
        let response = clampedTarget > value ? 0.045 : 0.12
        let coefficient = Float(1 - exp(-clampedDelta / response))
        value += (clampedTarget - value) * coefficient
        if value < 0.001 { value = 0 }
        return value
    }

    public mutating func reset() {
        value = 0
    }
}
