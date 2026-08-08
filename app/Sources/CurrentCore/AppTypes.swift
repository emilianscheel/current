import Foundation

public enum DictationPhase: String, Sendable, Codable, CaseIterable {
    case idle, armed, recording, transcribing, classifying, gatheringContext
    case generating, inserting
    case success, cancelled, error, paused

    public var displayName: String {
        switch self {
        case .idle: "Ready"
        case .armed: "Armed"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .classifying: "Understanding…"
        case .gatheringContext: "Reading context…"
        case .generating: "Writing…"
        case .inserting: "Inserting…"
        case .success: "Inserted"
        case .cancelled: "Cancelled"
        case .error: "Action needed"
        case .paused: "Paused"
        }
    }
}

public struct AutomaticUpdateInstallationState: Sendable, Equatable {
    public var dictationPhase: DictationPhase
    public var isBackgroundGenerationActive: Bool
    public var hasVisibleCurrentWindows: Bool
    public var secondsSinceUserInput: TimeInterval

    public init(
        dictationPhase: DictationPhase,
        isBackgroundGenerationActive: Bool = false,
        hasVisibleCurrentWindows: Bool,
        secondsSinceUserInput: TimeInterval
    ) {
        self.dictationPhase = dictationPhase
        self.isBackgroundGenerationActive = isBackgroundGenerationActive
        self.hasVisibleCurrentWindows = hasVisibleCurrentWindows
        self.secondsSinceUserInput = secondsSinceUserInput
    }
}

public enum AutomaticUpdateInstallationPolicy {
    public static let requiredUserIdleTime: TimeInterval = 5 * 60

    public static func canInstall(
        _ state: AutomaticUpdateInstallationState
    ) -> Bool {
        guard !state.isBackgroundGenerationActive,
              !state.hasVisibleCurrentWindows,
              state.secondsSinceUserInput >= requiredUserIdleTime else {
            return false
        }
        return state.dictationPhase == .idle
            || state.dictationPhase == .paused
    }
}

public struct AutomaticUpdateInstallationGate: Sendable {
    public private(set) var hasAllowedInstallation = false

    public init() {}

    public mutating func shouldInstall(
        _ state: AutomaticUpdateInstallationState
    ) -> Bool {
        guard !hasAllowedInstallation,
              AutomaticUpdateInstallationPolicy.canInstall(state) else {
            return false
        }
        hasAllowedInstallation = true
        return true
    }
}

public enum MenuBarPresentation {
    public static func symbol(for _: DictationPhase) -> String { "alternatingcurrent" }

    package static func modelStatusTitle(for state: ModelState) -> String {
        switch state {
        case .notInstalled: "Preparing…"
        case .downloading: "Downloading"
        case .verifying: "Verifying…"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed: "Error"
        }
    }

    package static func roundedDownloadPercent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    package static func downloadSpeedTitle(
        bytesPerSecond: Double?
    ) -> String? {
        guard let bytesPerSecond,
              bytesPerSecond.isFinite,
              bytesPerSecond > 0 else { return nil }
        let value: Double
        let unit: String
        if bytesPerSecond >= 1_000_000_000 {
            value = bytesPerSecond / 1_000_000_000
            unit = "GB/s"
        } else if bytesPerSecond >= 1_000_000 {
            value = bytesPerSecond / 1_000_000
            unit = "MB/s"
        } else if bytesPerSecond >= 1_000 {
            value = bytesPerSecond / 1_000
            unit = "KB/s"
        } else {
            value = bytesPerSecond
            unit = "B/s"
        }
        return String(
            format: value >= 100 ? "%.0f %@" : "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            unit
        )
    }

    package static func modelSubtitle(
        category: String,
        state: ModelState,
        metrics: ModelDownloadMetrics?,
        statusOverride: String? = nil
    ) -> String {
        if let statusOverride { return "\(category) · \(statusOverride)" }
        if case .downloading(let progress) = state {
            let fraction = metrics?.fractionCompleted ?? progress
            return "\(category) · Downloading · \(roundedDownloadPercent(fraction))%"
        }
        return "\(category) · \(modelStatusTitle(for: state))"
    }

    package static func onboardingModelStatus(
        state: ModelState,
        metrics: ModelDownloadMetrics?
    ) -> String {
        switch state {
        case .downloading(let progress):
            let fraction = metrics?.fractionCompleted ?? progress
            switch metrics?.stage {
            case .listing:
                return "Preparing download…"
            case .compiling:
                return "Preparing model…"
            case .downloading, nil:
                var components = [
                    "Downloading",
                    "\(roundedDownloadPercent(fraction))%",
                ]
                if let speed = downloadSpeedTitle(
                    bytesPerSecond: metrics?.bytesPerSecond
                ) {
                    components.append(speed)
                }
                return components.joined(separator: " · ")
            }
        case .notInstalled:
            return "Preparing…"
        case .verifying:
            return "Verifying…"
        case .loading:
            return "Loading…"
        case .ready:
            return "Ready"
        case .failed:
            return "Download failed"
        }
    }

    package static func onboardingActionTitle(
        completed: Bool,
        permissions: PermissionSnapshot,
        contextWorkerEnabled: Bool = true
    ) -> String? {
        if !completed { return "Onboarding…" }
        return permissions.allGranted(
            contextWorkerEnabled: contextWorkerEnabled
        ) ? nil : "Grant permissions…"
    }
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
    case intentClassificationFailed(String)
    case promptGenerationFailed(String)
    case insufficientPromptContext
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
        case .intentClassificationFailed(let reason):
            "Could not determine whether to dictate or follow an instruction: \(reason)"
        case .promptGenerationFailed(let reason): "Prompt generation failed: \(reason)"
        case .insufficientPromptContext: "Not enough context to generate this safely."
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
        case .screenRecording: "Current prefers Accessibility text from recently active apps. It takes a short-lived window screenshot only when useful text is unavailable. Current, Dock, Control Center, and SystemUIServer are excluded."
        case .inputMonitoring: "Current needs Input Monitoring to detect fn and to defer background context work while you interact with the Mac. macOS requires Current to restart after this is enabled."
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

    public func revokedPermissions(
        since previous: PermissionSnapshot
    ) -> [PermissionKind] {
        PermissionKind.allCases.filter {
            previous[$0].isGranted && !self[$0].isGranted
        }
    }

    public func restoredPermissions(
        since previous: PermissionSnapshot
    ) -> [PermissionKind] {
        PermissionKind.allCases.filter {
            !previous[$0].isGranted && self[$0].isGranted
        }
    }

    public func allGranted(contextWorkerEnabled: Bool) -> Bool {
        requiredPermissions(contextWorkerEnabled: contextWorkerEnabled)
            .allSatisfy { self[$0].isGranted }
    }

    public func firstMissing(contextWorkerEnabled: Bool) -> PermissionKind? {
        requiredPermissions(contextWorkerEnabled: contextWorkerEnabled)
            .first { !self[$0].isGranted }
    }

    private func requiredPermissions(
        contextWorkerEnabled: Bool
    ) -> [PermissionKind] {
        contextWorkerEnabled
            ? [.microphone, .accessibility, .screenRecording, .inputMonitoring]
            : [.microphone, .accessibility, .inputMonitoring]
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

public enum ModelDownloadStage: Sendable, Equatable {
    case listing
    case downloading
    case compiling
}

public struct ModelDownloadMetrics: Sendable, Equatable {
    public let fractionCompleted: Double
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?
    public let stage: ModelDownloadStage

    public init(
        fractionCompleted: Double,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        stage: ModelDownloadStage
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.stage = stage
    }

    public func hidingSpeed() -> Self {
        Self(
            fractionCompleted: fractionCompleted,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            stage: stage
        )
    }
}

package struct ModelDownloadMetricsTracker: Sendable {
    private struct Sample: Sendable {
        let date: Date
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private var maximumFraction = 0.0
    private var maximumBytes: Int64?
    private let speedWindow: TimeInterval = 2

    package init() {}

    package mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        maximumFraction = 0
        maximumBytes = nil
    }

    package mutating func update(
        fractionCompleted: Double,
        downloadedBytes: Int64?,
        totalBytes: Int64?,
        stage: ModelDownloadStage,
        at date: Date = Date()
    ) -> ModelDownloadMetrics {
        let clampedFraction = min(max(fractionCompleted, 0), 1)
        maximumFraction = max(maximumFraction, clampedFraction)

        let bytes = downloadedBytes.map { max($0, maximumBytes ?? 0) }
        if let bytes { maximumBytes = bytes }

        var bytesPerSecond: Double?
        if stage == .downloading, let bytes {
            samples.append(Sample(date: date, bytes: bytes))
            samples.removeAll {
                date.timeIntervalSince($0.date) > speedWindow
            }
            if let first = samples.first,
               let last = samples.last {
                let elapsed = last.date.timeIntervalSince(first.date)
                let transferred = last.bytes - first.bytes
                if elapsed >= 0.25, transferred > 0 {
                    bytesPerSecond = Double(transferred) / elapsed
                }
            }
        } else {
            samples.removeAll(keepingCapacity: true)
        }

        return ModelDownloadMetrics(
            fractionCompleted: maximumFraction,
            downloadedBytes: bytes,
            totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond,
            stage: stage
        )
    }
}

public struct HardwareSupport: Sendable, Equatable {
    public static let minimumMemoryBytes: UInt64 = 8 * 1_073_741_824
    public static let contextWorkerMinimumMemoryBytes: UInt64 =
        16 * 1_073_741_824

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
        isAppleSilicon
            && (generation ?? 0) >= 1
            && memoryBytes >= Self.minimumMemoryBytes
    }

    public var supportsContextWorker: Bool {
        isSupported && memoryBytes >= Self.contextWorkerMinimumMemoryBytes
    }

    public func contextWorkerEnabled(requested: Bool) -> Bool {
        requested && supportsContextWorker
    }

    public var reason: String {
        if !isAppleSilicon { return "Current requires an Apple-silicon Mac." }
        if (generation ?? 0) < 1 { return "Current requires an Apple M1 or newer chip." }
        if memoryBytes < Self.minimumMemoryBytes {
            return "Current requires at least 8 GB of unified memory."
        }
        if !supportsContextWorker {
            return "Dictation-first mode. Context features require at least 16 GB of unified memory."
        }
        return "Supported"
    }
}

public enum ModelPreparationPolicy {
    public static func shouldPrepareContextModel(
        hardware: HardwareSupport,
        contextWorkerEnabled: Bool
    ) -> Bool {
        hardware.supportsContextWorker && contextWorkerEnabled
    }
}

public enum OnboardingStep: String, Codable, Sendable, CaseIterable {
    case welcome, microphone, accessibility, screenRecording, inputMonitoring
    case restart, model, practice, preferences, trial, complete
}

public enum OnboardingFlow {
    public static func initialStep(
        saved: OnboardingStep,
        completed: Bool,
        permissions: PermissionSnapshot,
        modelInstalled: Bool,
        contextWorkerEnabled: Bool = true,
        restartRequired: Bool = false
    ) -> OnboardingStep {
        var saved = !contextWorkerEnabled && saved == .screenRecording
            ? OnboardingStep.inputMonitoring : saved
        let steps = visibleSteps(
            permissions: permissions,
            contextWorkerEnabled: contextWorkerEnabled,
            restartRequired: restartRequired
        )
        if !steps.contains(saved) { saved = .model }
        if !completed, saved == .welcome { return .welcome }
        if let missing = permissions.firstMissing(
            contextWorkerEnabled: contextWorkerEnabled
        ) {
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

    public static func automaticDestination(
        from step: OnboardingStep,
        permissions: PermissionSnapshot,
        contextWorkerEnabled: Bool = true,
        restartRequired: Bool = false
    ) -> OnboardingStep? {
        let permissionGranted = switch step {
        case .microphone: permissions.microphone.isGranted
        case .accessibility: permissions.accessibility.isGranted
        case .screenRecording: permissions.screenRecording.isGranted
        case .inputMonitoring: permissions.inputMonitoring.isGranted
        default: false
        }
        guard permissionGranted else { return nil }
        return adjacentStep(
            from: step,
            direction: 1,
            permissions: permissions,
            contextWorkerEnabled: contextWorkerEnabled,
            restartRequired: restartRequired
        )
    }

    public static func adjacentStep(
        from step: OnboardingStep,
        direction: Int,
        permissions: PermissionSnapshot,
        contextWorkerEnabled: Bool,
        restartRequired: Bool = false
    ) -> OnboardingStep? {
        let steps = visibleSteps(
            permissions: permissions,
            contextWorkerEnabled: contextWorkerEnabled,
            restartRequired: restartRequired
        )
        guard let index = steps.firstIndex(of: step) else { return nil }
        let destination = index + direction
        guard steps.indices.contains(destination) else { return nil }
        return steps[destination]
    }

    private static func visibleSteps(
        permissions: PermissionSnapshot,
        contextWorkerEnabled: Bool,
        restartRequired: Bool
    ) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            if step == .screenRecording { return contextWorkerEnabled }
            if step == .restart {
                return restartRequired && !permissions.allGranted(
                    contextWorkerEnabled: contextWorkerEnabled
                )
            }
            return true
        }
    }
}

public enum OnboardingArrowKey: Sendable {
    case left, right
}

public enum OnboardingKeyboardAction: Equatable, Sendable {
    case back, advance
}

public enum OnboardingKeyboardNavigation {
    public static func action(
        for key: OnboardingArrowKey,
        isEditingText: Bool,
        canGoBack: Bool,
        canAdvance: Bool
    ) -> OnboardingKeyboardAction? {
        return switch key {
        case .left where canGoBack: .back
        case .right where !isEditingText && canAdvance: .advance
        default: nil
        }
    }
}
