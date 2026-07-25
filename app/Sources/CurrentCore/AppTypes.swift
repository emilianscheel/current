import Foundation

public enum DictationPhase: String, Sendable, Codable, CaseIterable {
    case idle, armed, recording, transcribing, classifying, generating, inserting
    case success, cancelled, error, paused

    public var displayName: String {
        switch self {
        case .idle: "Ready"
        case .armed: "Armed"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .classifying: "Understanding…"
        case .generating: "Writing…"
        case .inserting: "Inserting…"
        case .success: "Inserted"
        case .cancelled: "Cancelled"
        case .error: "Action needed"
        case .paused: "Paused"
        }
    }
}

public enum MenuBarPresentation {
    public static func symbol(for _: DictationPhase) -> String { "alternatingcurrent" }
}

public struct DictationSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

public enum CurrentError: LocalizedError, Sendable, Equatable {
    case unsupportedHardware(String)
    case permissionMissing(PermissionKind)
    case noMicrophone
    case recordingTooShort
    case modelUnavailable(String)
    case transcriptionFailed(String)
    case promptGenerationFailed(String)
    case insertionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware(let reason): reason
        case .permissionMissing(let permission): "\(permission.title) permission is required."
        case .noMicrophone: "No microphone is available."
        case .recordingTooShort: "Keep holding fn while you speak."
        case .modelUnavailable(let reason): "A local model is unavailable: \(reason)"
        case .transcriptionFailed(let reason): "Transcription failed: \(reason)"
        case .promptGenerationFailed(let reason): "Prompt generation failed: \(reason)"
        case .insertionFailed(let reason): "Text was copied because insertion failed: \(reason)"
        case .cancelled: "Dictation was cancelled."
        }
    }
}

public enum PermissionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case microphone, accessibility, screenRecording, inputMonitoring
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    public var explanation: String {
        switch self {
        case .microphone: "Current records only while you hold fn. Audio stays in memory and is processed on this Mac."
        case .accessibility: "Current needs Accessibility to insert completed text into the field you are using."
        case .screenRecording: "Current takes short-lived screenshots every 30 seconds and after typing settles to maintain local, per-app context documents. Current itself is excluded, but other visible sensitive information may be included."
        case .inputMonitoring: "Current needs Input Monitoring to detect fn and schedule context capture after typing settles in another app. macOS requires Current to restart after this is enabled."
        }
    }
}

public enum PermissionState: String, Codable, Sendable {
    case unknown, notDetermined, denied, granted
    public var isGranted: Bool { self == .granted }
}

public struct PermissionSnapshot: Sendable, Equatable {
    public var microphone: PermissionState
    public var accessibility: PermissionState
    public var screenRecording: PermissionState
    public var inputMonitoring: PermissionState

    public init(
        microphone: PermissionState = .unknown,
        accessibility: PermissionState = .unknown,
        screenRecording: PermissionState = .unknown,
        inputMonitoring: PermissionState = .unknown
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.inputMonitoring = inputMonitoring
    }

    public subscript(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone: microphone
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        case .inputMonitoring: inputMonitoring
        }
    }

    public var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { self[$0].isGranted }
    }

    public var firstMissing: PermissionKind? {
        PermissionKind.allCases.first { !self[$0].isGranted }
    }
}

public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case loading
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }
}

public struct HardwareSupport: Sendable, Equatable {
    public let isAppleSilicon: Bool
    public let generation: Int?
    public let memoryBytes: UInt64
    public let modelName: String

    public init(isAppleSilicon: Bool, generation: Int?, memoryBytes: UInt64, modelName: String) {
        self.isAppleSilicon = isAppleSilicon
        self.generation = generation
        self.memoryBytes = memoryBytes
        self.modelName = modelName
    }

    public var isSupported: Bool {
        isAppleSilicon && (generation ?? 0) >= 3 && memoryBytes >= 16 * 1_073_741_824
    }

    public var reason: String {
        if !isAppleSilicon { return "Current requires an Apple-silicon Mac." }
        if (generation ?? 0) < 3 { return "Current requires an M3 or newer Apple chip." }
        if memoryBytes < 16 * 1_073_741_824 { return "Current requires at least 16 GB of unified memory." }
        return "Supported"
    }
}

public enum OnboardingStep: String, Codable, Sendable, CaseIterable {
    case welcome, microphone, accessibility, screenRecording, inputMonitoring
    case restart, model, practice, preferences, complete
}

public enum OnboardingFlow {
    public static func initialStep(
        saved: OnboardingStep,
        completed: Bool,
        permissions: PermissionSnapshot,
        modelInstalled: Bool
    ) -> OnboardingStep {
        if !completed, saved == .welcome { return .welcome }
        if let missing = permissions.firstMissing {
            switch missing {
            case .microphone: return .microphone
            case .accessibility: return .accessibility
            case .screenRecording: return .screenRecording
            case .inputMonitoring: return .inputMonitoring
            }
        }
        if !modelInstalled { return saved == .restart ? .model : (completed ? .model : saved) }
        if saved == .restart { return .model }
        return completed ? .complete : saved
    }

    public static func automaticDestination(from step: OnboardingStep, permissions: PermissionSnapshot) -> OnboardingStep? {
        switch step {
        case .microphone where permissions.microphone.isGranted: .accessibility
        case .accessibility where permissions.accessibility.isGranted: .screenRecording
        case .screenRecording where permissions.screenRecording.isGranted: .inputMonitoring
        case .inputMonitoring where permissions.inputMonitoring.isGranted: .restart
        default: nil
        }
    }
}
