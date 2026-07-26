import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum VoiceIntent: String, Codable, Sendable, CaseIterable {
    case direct
    case prompt
    case uncertain
}

public struct IntentDecision: Codable, Sendable, Equatable {
    public let intent: VoiceIntent
    public let confidence: Double

    public init(intent: VoiceIntent, confidence: Double) {
        self.intent = intent
        self.confidence = min(1, max(0, confidence))
    }

    public var effectiveIntent: VoiceIntent {
        intent == .uncertain ? .direct : intent
    }
}

public struct VoiceInteractionRequest: Sendable, Equatable {
    public let transcript: String
    public let context: DictationContext

    public init(transcript: String, context: DictationContext) {
        self.transcript = transcript
        self.context = context
    }
}

public struct PromptResponse: Sendable, Equatable {
    public static let maximumCharacters = 12_000
    public let text: String

    public init(text: String) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw CurrentError.promptGenerationFailed("The model returned an empty response.")
        }
        guard cleaned.count <= Self.maximumCharacters else {
            throw CurrentError.promptGenerationFailed("The generated response was too long to insert safely.")
        }
        self.text = cleaned
    }
}

public enum ContextSource: String, Codable, Sendable, CaseIterable {
    case accessibility
    case visionOCR
}

public struct ContextBounds: Codable, Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ContextTextBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let source: ContextSource
    public let confidence: Float
    public let bounds: ContextBounds?

    public init(
        id: UUID = UUID(),
        text: String,
        source: ContextSource,
        confidence: Float = 1,
        bounds: ContextBounds? = nil
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.bounds = bounds
    }
}

public struct AppSessionID: RawRepresentable, Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

public struct AppSessionMetadata: Codable, Sendable, Equatable, Hashable {
    public var sessionID: AppSessionID
    public var applicationName: String
    public var bundleIdentifier: String?
    public var processIdentifier: pid_t
    public var startedAt: Date
    public var endedAt: Date?
    public var dayIdentifier: String
    public var iconRelativePath: String?
    public var sources: Set<ContextSource>

    public init(
        sessionID: AppSessionID = AppSessionID(),
        applicationName: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        startedAt: Date,
        endedAt: Date? = nil,
        dayIdentifier: String,
        iconRelativePath: String? = nil,
        sources: Set<ContextSource> = []
    ) {
        self.sessionID = sessionID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.dayIdentifier = dayIdentifier
        self.iconRelativePath = iconRelativePath
        self.sources = sources
    }

    public var isActive: Bool { endedAt == nil }
}

public struct ContextObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let capturedAt: Date
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowIdentifier: UInt32?
    public let windowTitle: String?
    public let displayIdentifier: UInt32?
    public let isFrontmost: Bool
    public let blocks: [ContextTextBlock]

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        windowIdentifier: UInt32? = nil,
        windowTitle: String? = nil,
        displayIdentifier: UInt32? = nil,
        isFrontmost: Bool = false,
        blocks: [ContextTextBlock]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowIdentifier = windowIdentifier
        self.windowTitle = windowTitle
        self.displayIdentifier = displayIdentifier
        self.isFrontmost = isFrontmost
        self.blocks = blocks.filter { !$0.text.isEmpty }
    }

    public var normalizedText: String {
        Self.normalized(
            blocks
                .sorted {
                    if $0.source != $1.source { return $0.source == .accessibility }
                    return $0.text < $1.text
                }
                .map(\.text)
                .joined(separator: "\n")
        )
    }

    public static func normalized(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .lowercased()
    }
}

public enum ContextCaptureTrigger: String, Codable, Sendable, Equatable {
    case backgroundRefresh
    case typingSettled
    case textCommitted
}

public struct ContextCaptureTarget: Codable, Sendable, Equatable, Hashable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowIdentifier: UInt32?
    public let windowTitle: String?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        windowIdentifier: UInt32? = nil,
        windowTitle: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowIdentifier = windowIdentifier
        self.windowTitle = windowTitle
    }
}

public enum ContextActivityKind: String, Codable, Sendable, Equatable {
    case launch
    case activation
    case keyboard
    case mouse
    case accessibility
    case typingSettled
    case textCommitted

    public var isUrgent: Bool {
        self == .typingSettled || self == .textCommitted
    }
}

public struct RecentApplicationActivity: Codable, Sendable, Equatable {
    public let target: ContextCaptureTarget
    public let kind: ContextActivityKind
    public let occurredAt: Date

    public init(
        target: ContextCaptureTarget,
        kind: ContextActivityKind,
        occurredAt: Date = Date()
    ) {
        self.target = target
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public struct ContextBackgroundPolicy: Sendable, Equatable {
    public var recencyInterval: TimeInterval
    public var normalRefreshDelay: TimeInterval
    public var urgentRefreshDelay: TimeInterval
    public var interJobSpacing: TimeInterval
    public var userIdleDelay: TimeInterval
    public var maximumRecentApplications: Int

    public init(
        recencyInterval: TimeInterval = 5 * 60,
        normalRefreshDelay: TimeInterval = 30,
        urgentRefreshDelay: TimeInterval = 3,
        interJobSpacing: TimeInterval = 10,
        userIdleDelay: TimeInterval = 2,
        maximumRecentApplications: Int = 12
    ) {
        self.recencyInterval = recencyInterval
        self.normalRefreshDelay = normalRefreshDelay
        self.urgentRefreshDelay = urgentRefreshDelay
        self.interJobSpacing = interJobSpacing
        self.userIdleDelay = userIdleDelay
        self.maximumRecentApplications = maximumRecentApplications
    }
}

public enum ContextBackgroundState: String, Codable, Sendable, Equatable {
    case idle
    case waitingForIdle
    case processing
    case suspendedDuringDictation
    case deferredForPower
    case degraded
}

public enum ContextApplicationExclusions {
    public static let bundleIdentifiers: Set<String> = [
        "local.Current",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "local.Current.ContextWorker",
    ]

    public static func contains(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        processIdentifier == ownProcessIdentifier
            || bundleIdentifier.map(bundleIdentifiers.contains) == true
    }
}

public struct ContextWorkerImagePayload: Codable, Sendable, Equatable {
    public static let maximumByteCount = 16 * 1_024 * 1_024

    public let bgraData: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(
        bgraData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        guard width > 0, height > 0,
              bytesPerRow >= width * 4,
              bgraData.count == bytesPerRow * height,
              bgraData.count <= Self.maximumByteCount else {
            throw CurrentError.modelUnavailable(
                "The context-worker image payload is invalid or too large."
            )
        }
        self.bgraData = bgraData
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

public struct ContextCoverageKey: Codable, Sendable, Equatable, Hashable {
    public let processIdentifier: pid_t
    public let windowIdentifier: UInt32?
    public let windowTitle: String?

    public init(
        processIdentifier: pid_t,
        windowIdentifier: UInt32? = nil,
        windowTitle: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.windowTitle = windowTitle
    }
}

public struct AccessibilityCoverage: Codable, Sendable, Equatable {
    public let key: ContextCoverageKey
    public let lastAttempt: Date
    public let lastUsefulObservation: Date?
    public let blockCount: Int
    public let normalizedCharacterCount: Int

    public init(
        key: ContextCoverageKey,
        lastAttempt: Date,
        lastUsefulObservation: Date?,
        blockCount: Int,
        normalizedCharacterCount: Int
    ) {
        self.key = key
        self.lastAttempt = lastAttempt
        self.lastUsefulObservation = lastUsefulObservation
        self.blockCount = blockCount
        self.normalizedCharacterCount = normalizedCharacterCount
    }

    public var isUseful: Bool {
        blockCount >= 3 || normalizedCharacterCount >= 40
    }
}

public enum ContextCaptureDecision: Sendable, Equatable {
    case accessibility(ContextObservation)
    case screenshotFallback(ContextCoverageKey)
    case unavailable
}

public struct LiveAppContext: Codable, Sendable, Equatable, Identifiable {
    public var id: AppSessionID { session.sessionID }
    public var session: AppSessionMetadata
    public var observationsByWindow: [String: ContextObservation]
    public var pendingObservations: [ContextObservation]

    public init(
        session: AppSessionMetadata,
        observationsByWindow: [String: ContextObservation] = [:],
        pendingObservations: [ContextObservation] = []
    ) {
        self.session = session
        self.observationsByWindow = observationsByWindow
        self.pendingObservations = pendingObservations
    }

    public var latestObservation: ContextObservation? {
        observationsByWindow.values.max { $0.capturedAt < $1.capturedAt }
    }

    public var visibleText: String {
        observationsByWindow.values
            .sorted { lhs, rhs in
                if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
                return lhs.capturedAt > rhs.capturedAt
            }
            .map { observation in
                let title = observation.windowTitle.map { "Window: \($0)\n" } ?? ""
                return title + observation.blocks.map(\.text).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }
}

public struct ContextDocumentUpdate: Codable, Sendable, Equatable {
    public let changed: Bool
    public let currentStateMarkdown: String
    public let activityEntryMarkdown: String?

    public init(
        changed: Bool,
        currentStateMarkdown: String,
        activityEntryMarkdown: String? = nil
    ) {
        self.changed = changed
        self.currentStateMarkdown = currentStateMarkdown
        self.activityEntryMarkdown = activityEntryMarkdown
    }
}

public struct PromptContextEnvelope: Sendable, Equatable {
    public let instruction: String
    public let focusedContext: DictationContext
    public let targetApplicationContext: String
    public let otherVisibleApplicationContexts: [String]

    public init(
        instruction: String,
        focusedContext: DictationContext,
        targetApplicationContext: String,
        otherVisibleApplicationContexts: [String]
    ) {
        self.instruction = instruction
        self.focusedContext = focusedContext
        self.targetApplicationContext = targetApplicationContext
        self.otherVisibleApplicationContexts = otherVisibleApplicationContexts
    }

    public func rendered(maximumCharacters: Int = 10_000) -> String {
        let selected = focusedContext.selectedText ?? ""
        let focusedSections = [
            "Instruction:\n\(instruction)",
            "Selected text:\n\(selected)",
            "Text before cursor:\n\(focusedContext.textBeforeCursor)",
            "Text after cursor:\n\(focusedContext.textAfterCursor)",
        ]
        var result = ""
        func appending(_ text: String, limit: Int, to result: inout String) {
            guard limit > 0, result.count < maximumCharacters else { return }
            let separator = result.isEmpty ? "" : "\n\n"
            let available = min(
                limit,
                maximumCharacters - result.count - separator.count
            )
            guard available > 0 else { return }
            result += separator + String(text.prefix(available))
        }

        let focusedBudget = min(3_000, maximumCharacters / 3)
        let perFocusedSection = max(1, focusedBudget / focusedSections.count)
        for section in focusedSections {
            appending(section, limit: perFocusedSection, to: &result)
        }

        let remaining = max(0, maximumCharacters - result.count)
        let otherBudget = otherVisibleApplicationContexts.isEmpty
            ? 0
            : Int(Double(remaining) * 0.35)
        let targetBudget = remaining - otherBudget
        appending(
            "Target application context:\n\(targetApplicationContext)",
            limit: targetBudget,
            to: &result
        )
        if !otherVisibleApplicationContexts.isEmpty {
            let perOtherContext = max(
                1,
                otherBudget / otherVisibleApplicationContexts.count
            )
            for context in otherVisibleApplicationContexts {
                appending(
                    "Other visible application context:\n\(context)",
                    limit: perOtherContext,
                    to: &result
                )
            }
        }
        return result
    }
}

public protocol ScreenContextProviding: Sendable {
    func start() async throws
    func stop() async
    func scheduleCapture(
        trigger: ContextCaptureTrigger,
        target: ContextCaptureTarget?
    ) async
    func recordActivity(_ activity: RecentApplicationActivity) async
    func setForegroundInteractionActive(_ active: Bool) async
}

public protocol AccessibilityContextProviding: Sendable {
    func refreshCoverage(
        for target: ContextCaptureTarget
    ) async -> ContextCaptureDecision
    func coverage(
        for target: ContextCaptureTarget
    ) async -> AccessibilityCoverage?
}

public protocol OCRProviding: Sendable {
    func recognizeText(in image: CGImage) async throws -> [ContextTextBlock]
}

public protocol ContextStructuringProviding: Sendable {
    func updateContextDocument(
        currentState: String,
        observations: [ContextObservation]
    ) async throws -> ContextDocumentUpdate
}

public protocol LocalIntelligenceProviding: Sendable {
    func classifyIntent(_ request: VoiceInteractionRequest) async -> IntentDecision
    func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult
    func generatePromptResponse(_ envelope: PromptContextEnvelope) async throws -> PromptResponse
}

public typealias LocalIntelligenceProvider = LocalIntelligenceProviding

public enum ModelRequestPriority: Int, Sendable, Comparable {
    case contextMaintenance = 0
    case dictationRefinement = 1
    case intentClassification = 2
    case promptGeneration = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor ModelRequestScheduler {
    private struct Waiter {
        let priority: ModelRequestPriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isBusy = false
    private var nextOrder: UInt64 = 0
    private var waiters: [Waiter] = []

    public init() {}

    public func withPermit<Value: Sendable>(
        priority: ModelRequestPriority,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire(priority: priority)
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(priority: ModelRequestPriority) async {
        guard isBusy else {
            isBusy = true
            return
        }
        let order = nextOrder
        nextOrder += 1
        await withCheckedContinuation { continuation in
            waiters.append(
                Waiter(
                    priority: priority,
                    order: order,
                    continuation: continuation
                )
            )
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        waiters.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.order < $1.order
        }
        waiters.removeFirst().continuation.resume()
    }
}

public actor AppleFoundationModelProvider:
    LocalIntelligenceProviding,
    ContextStructuringProviding
{
    public let scheduler: ModelRequestScheduler

    public init(scheduler: ModelRequestScheduler = ModelRequestScheduler()) {
        self.scheduler = scheduler
    }

    public func classifyIntent(_ request: VoiceInteractionRequest) async -> IntentDecision {
        if let deterministic = ConservativeIntentClassifier.classify(request.transcript) {
            return deterministic
        }
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            return IntentDecision(intent: .uncertain, confidence: 0)
        }
        do {
            return try await scheduler.withPermit(priority: .intentClassification) {
                let session = LanguageModelSession(
                    instructions: """
                    Classify spoken text for a universal Mac dictation app.
                    Return exactly DIRECT when the words should be typed literally.
                    Return exactly PROMPT when they instruct the app to create, rewrite, answer,
                    summarize, translate, or otherwise produce text using screen context.
                    Return exactly UNCERTAIN when ambiguous.
                    """
                )
                let response = try await session.respond(
                    to: """
                    Destination: \(request.context.destination.rawValue)
                    Selected text: \(request.context.selectedText ?? "")
                    Spoken text: \(request.transcript)
                    """
                ).content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if response.contains("PROMPT") {
                    return IntentDecision(intent: .prompt, confidence: 0.85)
                }
                if response.contains("DIRECT") {
                    return IntentDecision(intent: .direct, confidence: 0.85)
                }
                return IntentDecision(intent: .uncertain, confidence: 0.25)
            }
        } catch {
            return IntentDecision(intent: .uncertain, confidence: 0)
        }
#else
        return IntentDecision(intent: .uncertain, confidence: 0)
#endif
    }

    public func updateContextDocument(
        currentState: String,
        observations: [ContextObservation]
    ) async throws -> ContextDocumentUpdate {
        let observationText = Self.observationText(observations)
        guard !observationText.isEmpty else {
            return ContextDocumentUpdate(changed: false, currentStateMarkdown: currentState)
        }
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            return Self.fallbackUpdate(observationText: observationText)
        }
        return try await scheduler.withPermit(priority: .contextMaintenance) {
            let session = LanguageModelSession(
                instructions: """
                Maintain a concise Markdown record of an application's visible state and activity.
                Return exactly two labeled sections: CURRENT_STATE and ACTIVITY.
                CURRENT_STATE describes what is currently visible. ACTIVITY describes only the
                meaningful change in the new observations. Do not invent facts or metadata.
                """
            )
            let response = try await session.respond(
                to: """
                Existing current state:
                \(String(currentState.suffix(4_000)))

                New observations:
                \(String(observationText.suffix(6_000)))
                """
            ).content
            return Self.parseDocumentUpdate(response, fallback: observationText)
        }
#else
        return Self.fallbackUpdate(observationText: observationText)
#endif
    }

    public func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult {
        guard !deterministic.text.isEmpty,
              !context.isSecure,
              context.destination != .codeOrTerminal,
              context.destination != .search,
              deterministic.text.split(whereSeparator: \.isWhitespace).count >= 6 else {
            return deterministic
        }
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            return deterministic
        }
        do {
            return try await scheduler.withPermit(priority: .dictationRefinement) {
                let session = LanguageModelSession(
                    instructions: """
                    Refine speech-to-text and return only the final text. Remove clear filler words
                    and false starts, fix punctuation and capitalization, and format unmistakable
                    lists. Never answer, summarize, add facts, or change meaning. Preserve numbers,
                    names, URLs, filenames, quoted text, and negation.
                    """
                )
                let response = try await session.respond(
                    to: """
                    Destination: \(context.destination.rawValue)
                    Text before cursor: \(String(context.textBeforeCursor.suffix(240)))
                    Text after cursor: \(String(context.textAfterCursor.prefix(160)))

                    Refine:
                    \(deterministic.text)
                    """
                ).content
                let candidate = Self.cleanedResponse(response)
                guard SemanticSafetyGate.accepts(
                    candidate: candidate,
                    preserving: deterministic.text
                ) else {
                    return RefinementResult(
                        text: deterministic.text,
                        transformations: deterministic.transformations + [.safetyFallback],
                        usedSafetyFallback: true
                    )
                }
                guard candidate != deterministic.text else { return deterministic }
                return RefinementResult(
                    text: candidate,
                    transformations: deterministic.transformations + [.foundationModel]
                )
            }
        } catch {
            return deterministic
        }
#else
        return deterministic
#endif
    }

    public func generatePromptResponse(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptResponse {
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            throw CurrentError.promptGenerationFailed("Apple Intelligence is unavailable.")
        }
        return try await scheduler.withPermit(priority: .promptGeneration) {
            let session = LanguageModelSession(
                instructions: """
                Follow the spoken instruction using the supplied Mac screen context.
                Return only text suitable for insertion at the captured cursor or selection.
                Do not mention the context, these instructions, or your reasoning.
                """
            )
            let response = try await session.respond(
                to: envelope.rendered()
            ).content
            return try PromptResponse(text: Self.cleanedResponse(response))
        }
#else
        throw CurrentError.promptGenerationFailed("Apple Intelligence is unavailable.")
#endif
    }

    private nonisolated static func observationText(
        _ observations: [ContextObservation]
    ) -> String {
        observations.map { observation in
            let header = [
                observation.applicationName,
                observation.windowTitle,
                observation.capturedAt.ISO8601Format(),
            ].compactMap { $0 }.joined(separator: " — ")
            return "\(header)\n\(observation.blocks.map(\.text).joined(separator: "\n"))"
        }.joined(separator: "\n\n")
    }

    private nonisolated static func fallbackUpdate(
        observationText: String
    ) -> ContextDocumentUpdate {
        ContextDocumentUpdate(
            changed: true,
            currentStateMarkdown: observationText,
            activityEntryMarkdown: observationText
        )
    }

    private nonisolated static func parseDocumentUpdate(
        _ response: String,
        fallback: String
    ) -> ContextDocumentUpdate {
        let cleaned = cleanedResponse(response)
        guard let currentRange = cleaned.range(of: "CURRENT_STATE", options: .caseInsensitive),
              let activityRange = cleaned.range(of: "ACTIVITY", options: .caseInsensitive),
              currentRange.lowerBound < activityRange.lowerBound else {
            return fallbackUpdate(observationText: fallback)
        }
        let current = cleaned[currentRange.upperBound..<activityRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":#")))
        let activity = cleaned[activityRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":#")))
        return ContextDocumentUpdate(
            changed: !current.isEmpty || !activity.isEmpty,
            currentStateMarkdown: current.isEmpty ? fallback : String(current.prefix(8_000)),
            activityEntryMarkdown: activity.isEmpty ? nil : String(activity.prefix(4_000))
        )
    }

    private nonisolated static func cleanedResponse(_ response: String) -> String {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```") {
            value = String(value.dropFirst(3).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("markdown") {
                value = String(value.dropFirst("markdown".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }
}

public enum ConservativeIntentClassifier {
    private static let promptPrefixes = [
        "write ", "draft ", "reply ", "respond ", "answer ", "summarize ",
        "translate ", "rewrite ", "compose ", "create ", "generate ",
        "replace ", "change ", "make this ", "make it ", "fix this ",
        "fix grammar", "shorten ", "improve ", "uppercase", "lowercase",
        "title case", "delete", "remove that",
        "schreib ", "verfasse ", "antworte ", "fasse ", "übersetze ",
        "rédige ", "réponds ", "résume ", "traduis ",
        "escribe ", "responde ", "resume ", "traduce ",
        "scrivi ", "rispondi ", "riassumi ", "traduci ",
    ]

    public static func classify(_ text: String) -> IntentDecision? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !normalized.isEmpty else {
            return IntentDecision(intent: .uncertain, confidence: 0)
        }
        if promptPrefixes.contains(where: normalized.hasPrefix) {
            return IntentDecision(intent: .prompt, confidence: 0.95)
        }
        return nil
    }
}
