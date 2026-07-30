import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class DictationCoordinator {
    private struct PromptTimings {
        var transcription = 0
        var classification = 0
        var contextPreparation = 0
        var generation = 0
    }
    private struct PreparedPromptContext: Sendable {
        let envelope: PromptContextEnvelope
        let durationMilliseconds: Int
    }
    public enum ExecutionMode: Sendable, Equatable {
        case fast
        case rich
    }

    private struct PendingPromptBypass {
        let session: DictationSession
        let rawText: String
        let context: DictationContext
        let captureTarget: ContextCaptureTarget?
    }

    public private(set) var phase: DictationPhase = .idle
    public private(set) var currentSession: DictationSession?
    public private(set) var lastTranscription = ""
    public private(set) var partialTranscription = ""
    public private(set) var errorMessage: String?
    public private(set) var currentExecutionMode: ExecutionMode?
    public private(set) var lastPromptLatencyDiagnostics: PromptLatencyDiagnostics?
    public private(set) var promptLatencySamples: [PromptLatencyDiagnostics] = []
    public var promptLatencySummary: PromptLatencySummary? {
        guard !promptLatencySamples.isEmpty else { return nil }
        let values = promptLatencySamples.map(\.releaseToPasteMilliseconds).sorted()
        return .init(
            sampleCount: values.count,
            releaseToPasteP50Milliseconds: Self.percentile(0.50, values: values),
            releaseToPasteP95Milliseconds: Self.percentile(0.95, values: values)
        )
    }

    public let settings: SettingsStore
    public let model: ModelManager
    public let audio: AudioCaptureService
    public let insertion: InsertionService
    public let shortcut: ShortcutMonitor
    public let vocabulary: LearnedVocabularyStore
    public let intelligence: any LocalIntelligenceProviding
    public let intentRouter: any VoiceIntentRoutingProviding
    public let contextRepository: ContextRepository?
    public let promptContextPreparer: (any PromptContextPreparing)?
    public let conversationContext: ConversationContext?
    public var onPhaseChange: ((DictationPhase) -> Void)?
    public var onPartialTranscriptionChange: ((String) -> Void)?
    public var onTranscriptionCompleted: ((Date) -> Void)?
    public var onSuccessfulTranscription: ((String, Date) -> Void)?
    public var onTextCommitted: ((ContextCaptureTarget) -> Void)?
    public var onMonitoringChange: ((Bool) -> Void)?
    private var maximumDurationTask: Task<Void, Never>?
    private var transcriptProcessingTask: Task<Void, Never>?
    private var processingGeneration = UUID()
    private var pendingPromptBypass: PendingPromptBypass?
    private let clock = ContinuousClock()
    private let signposter = OSSignposter(
        subsystem: "com.emilianscheel.current",
        category: "PromptLatency"
    )
    private let latencyLogger = Logger(
        subsystem: "com.emilianscheel.current",
        category: "PromptLatency"
    )

    public init(
        settings: SettingsStore = .shared,
        model: ModelManager = ModelManager(),
        audio: AudioCaptureService = AudioCaptureService(),
        insertion: InsertionService = InsertionService(),
        shortcut: ShortcutMonitor = ShortcutMonitor(),
        vocabulary: LearnedVocabularyStore = LearnedVocabularyStore(),
        intelligence: any LocalIntelligenceProviding = AppleFoundationModelProvider(),
        intentRouter: any VoiceIntentRoutingProviding = AppleVoiceIntentRouter(),
        contextRepository: ContextRepository? = nil,
        promptContextPreparer: (any PromptContextPreparing)? = nil,
        conversationContext: ConversationContext? = nil
    ) {
        self.settings = settings
        self.model = model
        self.audio = audio
        self.insertion = insertion
        self.shortcut = shortcut
        self.vocabulary = vocabulary
        self.intelligence = intelligence
        self.intentRouter = intentRouter
        self.contextRepository = contextRepository
        self.promptContextPreparer = promptContextPreparer
        self.conversationContext = conversationContext
        self.audio.selectedDeviceID = settings.inputDeviceID
        shortcut.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleShortcut(event) }
        }
        shortcut.onReturnKeyDown = { [weak self] in
            Task { @MainActor [weak self] in
                self?.insertRawTranscriptionIfPending()
            }
        }
    }

    public func startMonitoring() {
        guard settings.isEnabled else {
            setPhase(.paused)
            onMonitoringChange?(false)
            return
        }
        shortcut.holdThreshold = .milliseconds(settings.holdThresholdMilliseconds)
        shortcut.fallbackPreset = settings.fallbackShortcut
        do {
            try shortcut.start()
            Task {
                await intentRouter.setEnabled(settings.contextWorkerEnabled)
            }
            setPhase(.idle)
            onMonitoringChange?(true)
        } catch {
            fail(error)
        }
    }

    public func stopMonitoring() {
        shortcut.stop()
        cancel()
        setPhase(.paused)
        onMonitoringChange?(false)
        Task { await intentRouter.setEnabled(false) }
    }

    public func toggleEnabled() {
        settings.isEnabled.toggle()
        settings.isEnabled ? startMonitoring() : stopMonitoring()
    }

    public func beginFromMenu() {
        // The menu is an explicit request to dictate. If Current was paused,
        // resume global monitoring first so this capture works and fn keeps
        // working for subsequent captures. Previously the paused phase fell
        // through to stopAndTranscribe(), which had no session and silently
        // did nothing.
        if !settings.isEnabled || phase == .paused {
            settings.isEnabled = true
            startMonitoring()
        }
        guard phase == .idle || phase == .success || phase == .error else {
            stopAndTranscribe()
            return
        }
        beginRecording()
    }

    public func copyLastTranscription() {
        guard !lastTranscription.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscription, forType: .string)
    }

    public func pasteLastTranscription() {
        guard !lastTranscription.isEmpty else { return }
        Task {
            insertion.captureTarget()
            let captureTarget = insertion.contextCaptureTarget
            let result = try? await insertion.insert(
                lastTranscription,
                context: insertion.currentContext,
                restoreClipboard: true
            )
            if result != .copied, let captureTarget {
                onTextCommitted?(captureTarget)
            }
        }
    }

    public func clearLastTranscription() { lastTranscription = "" }

    public func undoLastInsertion() {
        Task { _ = await insertion.undoLastInsertion() }
    }

    public func forgetLearnedWords() {
        vocabulary.forgetAll()
    }

    public func cancel() {
        guard currentSession != nil else { return }
        let sessionID = currentSession?.id
        processingGeneration = UUID()
        clearPromptBypass()
        maximumDurationTask?.cancel()
        transcriptProcessingTask?.cancel()
        transcriptProcessingTask = nil
        currentSession = nil
        currentExecutionMode = nil
        audio.cancel()
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        Task { await model.transcription.stopPartialTranscription() }
        if let sessionID {
            Task { await intentRouter.cancel(sessionID: sessionID) }
        }
        insertion.clearTarget()
        setPhase(.cancelled)
        scheduleIdle()
    }

    private func handleShortcut(_ event: ShortcutEvent) {
        guard settings.isEnabled else { return }
        switch event {
        case .armed:
            guard phase == .idle else { return }
            insertion.captureTarget()
            setPhase(.armed)
        case .pressed: beginRecording()
        case .released: stopAndTranscribe()
        case .cancelled:
            if currentSession != nil { cancel() }
            else if phase == .armed {
                insertion.clearTarget()
                setPhase(.idle)
            }
        }
    }

    private func beginRecording() {
        guard currentSession == nil, model.state.isReady else {
            if !model.state.isReady { fail(CurrentError.modelUnavailable("Download or loading is still in progress.")) }
            return
        }
        do {
            processingGeneration = UUID()
            clearPromptBypass()
            let session = DictationSession()
            let executionMode: ExecutionMode = settings.contextWorkerEnabled
                ? .rich : .fast
            if phase != .armed { insertion.captureTarget() }
            currentSession = session
            currentExecutionMode = executionMode
            if executionMode == .rich {
                Task {
                    [
                        intentRouter,
                        promptContextPreparer,
                        context = insertion.currentContext,
                        target = insertion.contextCaptureTarget,
                        continuousContextEnabled = settings.continuousContextEnabled,
                    ] in
                    async let routing: Void = intentRouter.prepare(
                        sessionID: session.id,
                        context: IntentRoutingContext(context: context)
                    )
                    async let contextPrefetch: Void = promptContextPreparer?.prefetch(
                        focusedContext: context,
                        target: target,
                        continuousContextEnabled: continuousContextEnabled
                    ) ?? ()
                    let conversationID = await conversationContext?
                        .snapshot().conversationID ?? UUID()
                    async let generationPrewarm: Void = intelligence.prewarmPrompt(
                        conversationID: conversationID
                    )
                    _ = await (routing, contextPrefetch, generationPrewarm)
                }
            }
            try audio.start()
            let transcription = model.transcription
            audio.setSampleHandler { samples in
                Task { await transcription.consumePartialSamples(samples) }
            }
            Task { [weak self] in
                if executionMode == .rich {
                    await transcription.prewarmRefinement()
                }
                await transcription.startPartialTranscription { [weak self] preview in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentSession?.id == session.id else { return }
                        self.partialTranscription = preview
                        self.onPartialTranscriptionChange?(preview)
                    }
                }
            }
            setPhase(.recording)
            maximumDurationTask?.cancel()
            maximumDurationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.settings.maximumRecordingDuration ?? 120))
                guard !Task.isCancelled, let self, self.currentSession?.id == session.id else { return }
                self.stopAndTranscribe()
            }
        } catch { fail(error) }
    }

    private func stopAndTranscribe() {
        guard let session = currentSession,
              let executionMode = currentExecutionMode else { return }
        maximumDurationTask?.cancel()
        let samples = audio.stop()
        let releasedAt = clock.now
        let minimumSamples = Int(settings.minimumRecordingDuration * 16_000)
        guard samples.count >= minimumSamples else {
            fail(CurrentError.recordingTooShort)
            return
        }
        setPhase(.transcribing)
        let context = insertion.currentContext
        let captureTarget = insertion.contextCaptureTarget
        let vocabularyEntries = vocabulary.entries
        let generation = UUID()
        processingGeneration = generation
        clearPromptBypass()
        transcriptProcessingTask?.cancel()
        transcriptProcessingTask = Task {
            [weak self, transcription = model.transcription] in
            do {
                await transcription.stopPartialTranscription()
                let rawText = try await transcription.transcribe(samples)
                guard let self, self.currentSession?.id == session.id else { return }
                let text: String
                let directDictation: Bool
                var committedIntent: VoiceIntent = .direct
                var committedInstruction: String?
                var promptTimings: PromptTimings?
                if executionMode == .fast {
                    self.clearPromptBypass()
                    text = DeterministicRefiner.refine(
                        rawText,
                        context: context,
                        vocabulary: vocabularyEntries
                    ).text
                    directDictation = true
                } else {
                    self.setPhase(.classifying)
                    let classificationStartedAt = self.clock.now
                    let speculativeContext = Task {
                        let startedAt = self.clock.now
                        let envelope = try await self.preparePromptContext(
                            instruction: rawText,
                            focusedContext: context,
                            target: captureTarget,
                            scope: .retrieved
                        )
                        return PreparedPromptContext(
                            envelope: envelope,
                            durationMilliseconds: Self.milliseconds(
                                from: startedAt,
                                to: self.clock.now
                            )
                        )
                    }
                    let decision = try await self.intentRouter.classify(
                        IntentRoutingRequest(
                            transcript: rawText,
                            context: context
                        ),
                        sessionID: session.id
                    )
                    var timings = PromptTimings()
                    timings.transcription = Self.milliseconds(
                        from: releasedAt,
                        to: classificationStartedAt
                    )
                    timings.classification = Self.milliseconds(
                        from: classificationStartedAt,
                        to: self.clock.now
                    )
                    guard self.isCurrent(
                        sessionID: session.id,
                        generation: generation
                    ) else { return }
                    directDictation = decision.intent == .direct
                    committedIntent = decision.intent
                    switch decision.intent {
                    case .prompt:
                        committedInstruction = rawText
                        let envelope: PromptContextEnvelope
                        self.pendingPromptBypass = PendingPromptBypass(
                            session: session,
                            rawText: rawText,
                            context: context,
                            captureTarget: captureTarget
                        )
                        self.shortcut.setReturnInterceptionEnabled(true)
                        self.setPhase(.gatheringContext)
                        if decision.contextScope == .retrieved {
                            let prepared = try await speculativeContext.value
                            envelope = prepared.envelope
                            timings.contextPreparation = prepared.durationMilliseconds
                        } else {
                            speculativeContext.cancel()
                            let contextStartedAt = self.clock.now
                            envelope = try await self.preparePromptContext(
                                instruction: rawText,
                                focusedContext: context,
                                target: captureTarget,
                                scope: decision.contextScope
                            )
                            timings.contextPreparation = Self.milliseconds(
                                from: contextStartedAt,
                                to: self.clock.now
                            )
                        }
                        if self.shortcut.consumeReturnInterceptionRequest() {
                            self.insertRawTranscriptionIfPending()
                            return
                        }
                        try Task.checkCancellation()
                        guard self.isCurrent(
                            sessionID: session.id,
                            generation: generation
                        ) else { return }
                        self.setPhase(.generating)
                        let generationStartedAt = self.clock.now
                        let conversationID = await self.conversationContext?
                            .snapshot().conversationID ?? UUID()
                        let disposition = try await self.intelligence
                            .generatePromptDisposition(.init(
                                envelope: envelope,
                                conversationID: conversationID,
                                contextScope: decision.contextScope
                            ))
                        timings.generation = Self.milliseconds(
                            from: generationStartedAt,
                            to: self.clock.now
                        )
                        promptTimings = timings
                        if self.shortcut.consumeReturnInterceptionRequest() {
                            self.insertRawTranscriptionIfPending()
                            return
                        }
                        try Task.checkCancellation()
                        guard self.isCurrent(
                            sessionID: session.id,
                            generation: generation
                        ) else { return }
                        switch disposition {
                        case let .generated(response): text = response.text
                        case .insufficientContext:
                            throw CurrentError.insufficientPromptContext
                        }
                    case .direct:
                        speculativeContext.cancel()
                        self.clearPromptBypass()
                        let deterministic = DeterministicRefiner.refine(
                            rawText,
                            context: context,
                            vocabulary: vocabularyEntries
                        )
                        let refinement = await self.intelligence.refineDictation(
                            deterministic,
                            context: context
                        )
                        text = refinement.text
                    case .uncertain:
                        speculativeContext.cancel()
                        throw CurrentError.intentClassificationFailed(
                            "The local models were uncertain."
                        )
                    }
                }
                guard self.isCurrent(sessionID: session.id, generation: generation) else {
                    return
                }
                if directDictation,
                   let selection = context.selectedText,
                   let learned = Self.learnedCorrection(
                       from: selection,
                       to: text
                   ) {
                    self.vocabulary.learn(
                        spokenForm: learned.spoken,
                        writtenForm: learned.written
                    )
                }
                self.clearPromptBypass()
                self.setPhase(.inserting)
                let insertionStartedAt = self.clock.now
                let targetProcessIdentifier = self.insertion.targetApplicationPresentation?.processIdentifier
                let result = try await self.insertion.insert(
                    text,
                    context: context,
                    restoreClipboard: true
                )
                guard self.isCurrent(sessionID: session.id, generation: generation) else {
                    return
                }
                if let promptTimings {
                    let diagnostics = PromptLatencyDiagnostics(
                        transcriptionMilliseconds: promptTimings.transcription,
                        classificationMilliseconds: promptTimings.classification,
                        contextPreparationMilliseconds: promptTimings.contextPreparation,
                        generationMilliseconds: promptTimings.generation,
                        insertionMilliseconds: Self.milliseconds(
                            from: insertionStartedAt,
                            to: self.clock.now
                        ),
                        releaseToPasteMilliseconds: Self.milliseconds(
                            from: releasedAt,
                            to: self.clock.now
                        )
                    )
                    self.lastPromptLatencyDiagnostics = diagnostics
                    self.promptLatencySamples.append(diagnostics)
                    if self.promptLatencySamples.count > 200 {
                        self.promptLatencySamples.removeFirst(
                            self.promptLatencySamples.count - 200
                        )
                    }
                    self.signposter.emitEvent("Prompt release-to-paste completed")
                    self.latencyLogger.info(
                        "Prompt latency ms transcription=\(diagnostics.transcriptionMilliseconds, privacy: .public) classification=\(diagnostics.classificationMilliseconds, privacy: .public) context=\(diagnostics.contextPreparationMilliseconds, privacy: .public) generation=\(diagnostics.generationMilliseconds, privacy: .public) insertion=\(diagnostics.insertionMilliseconds, privacy: .public) total=\(diagnostics.releaseToPasteMilliseconds, privacy: .public)"
                    )
                }
                await self.completeInsertion(
                    text: text,
                    session: session,
                    context: context,
                    instruction: committedInstruction,
                    intent: committedIntent,
                    captureTarget: captureTarget,
                    targetProcessIdentifier: targetProcessIdentifier,
                    result: result
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrent(
                          sessionID: session.id,
                          generation: generation
                      ) else { return }
                if self.shortcut.consumeReturnInterceptionRequest(),
                   self.insertRawTranscriptionIfPending() {
                    return
                }
                self.currentSession = nil
                self.transcriptProcessingTask = nil
                self.fail(error)
            }
        }
    }

    @discardableResult
    public func insertRawTranscriptionIfPending() -> Bool {
        guard let pendingPromptBypass,
              phase == .gatheringContext || phase == .generating,
              currentSession?.id == pendingPromptBypass.session.id else {
            return false
        }
        let generation = UUID()
        processingGeneration = generation
        clearPromptBypass()
        transcriptProcessingTask?.cancel()
        setPhase(.inserting)
        let targetProcessIdentifier = insertion.targetApplicationPresentation?
            .processIdentifier
        transcriptProcessingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.insertion.insert(
                    pendingPromptBypass.rawText,
                    context: pendingPromptBypass.context,
                    restoreClipboard: true
                )
                guard self.isCurrent(
                    sessionID: pendingPromptBypass.session.id,
                    generation: generation
                ) else { return }
                await self.completeInsertion(
                    text: pendingPromptBypass.rawText,
                    session: pendingPromptBypass.session,
                    context: pendingPromptBypass.context,
                    instruction: nil,
                    intent: .direct,
                    captureTarget: pendingPromptBypass.captureTarget,
                    targetProcessIdentifier: targetProcessIdentifier,
                    result: result
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(
                    sessionID: pendingPromptBypass.session.id,
                    generation: generation
                ) else { return }
                self.currentSession = nil
                self.transcriptProcessingTask = nil
                self.fail(error)
            }
        }
        return true
    }

    private func isCurrent(sessionID: UUID, generation: UUID) -> Bool {
        currentSession?.id == sessionID && processingGeneration == generation
    }

    private func clearPromptBypass() {
        pendingPromptBypass = nil
        shortcut.clearReturnInterception()
    }

    private func completeInsertion(
        text: String,
        session: DictationSession,
        context: DictationContext,
        instruction: String?,
        intent: VoiceIntent,
        captureTarget: ContextCaptureTarget?,
        targetProcessIdentifier: pid_t?,
        result: InsertionService.Result
    ) async {
        clearPromptBypass()
        lastTranscription = text
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        onTranscriptionCompleted?(Date())
        if Self.shouldRecordContext(
            targetProcessIdentifier: targetProcessIdentifier,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            result: result,
            isSecure: context.isSecure,
            targetBundleIdentifier: context.bundleIdentifier
        ) {
            if ContextEngineeringFeatureFlags.conversationLedger {
                await conversationContext?.record(
                    instruction: instruction,
                    committedText: text,
                    intent: intent,
                    at: session.startedAt
                )
            }
            onSuccessfulTranscription?(text, session.startedAt)
        }
        if result != .copied, let captureTarget {
            onTextCommitted?(captureTarget)
        }
        currentSession = nil
        currentExecutionMode = nil
        transcriptProcessingTask = nil
        if result == .copied { errorMessage = "Copied — paste manually." }
        setPhase(result == .copied ? .error : .success)
        scheduleIdle()
    }

    private func fail(_ error: Error) {
        let sessionID = currentSession?.id
        processingGeneration = UUID()
        clearPromptBypass()
        audio.cancel()
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        Task { await model.transcription.stopPartialTranscription() }
        currentSession = nil
        currentExecutionMode = nil
        if let sessionID {
            Task { await intentRouter.cancel(sessionID: sessionID) }
        }
        insertion.clearTarget()
        errorMessage = error.localizedDescription
        setPhase(.error)
        scheduleIdle(delay: .seconds(2.5))
    }

    nonisolated public static func shouldRecordContext(
        targetProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t
    ) -> Bool {
        targetProcessIdentifier != currentProcessIdentifier
    }

    nonisolated public static func shouldRecordContext(
        targetProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t,
        result: InsertionService.Result,
        isSecure: Bool,
        targetBundleIdentifier: String?
    ) -> Bool {
        result != .copied
            && !isSecure
            && shouldRecordContext(
                targetProcessIdentifier: targetProcessIdentifier,
                currentProcessIdentifier: currentProcessIdentifier
            )
            && !ContextApplicationExclusions.contains(
                processIdentifier: targetProcessIdentifier ?? -1,
                bundleIdentifier: targetBundleIdentifier
            )
    }

    private func preparePromptContext(
        instruction: String,
        focusedContext: DictationContext,
        target: ContextCaptureTarget?,
        scope: PromptContextScope
    ) async throws -> PromptContextEnvelope {
        if let promptContextPreparer {
            return try await promptContextPreparer.prepare(
                instruction: instruction,
                focusedContext: focusedContext,
                target: target,
                continuousContextEnabled: settings.continuousContextEnabled,
                scope: scope
            )
        }
        if let contextRepository {
            return await contextRepository.promptContext(
                instruction: instruction,
                focusedContext: focusedContext,
                target: target,
                includeApplicationContext: settings.continuousContextEnabled,
                conversation: await conversationContext?.snapshot(),
                scope: scope
            )
        }
        return PromptContextEnvelope(
            instruction: instruction,
            focusedContext: focusedContext,
            sections: []
        )
    }

    public func clearConversationContext() async {
        await conversationContext?.clear()
    }

    nonisolated public static func learnedCorrection(
        from original: String,
        to corrected: String
    ) -> (spoken: String, written: String)? {
        let originalWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let correctedWords = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard originalWords.count == correctedWords.count else { return nil }
        let changes = zip(originalWords, correctedWords).filter {
            $0.0.compare(
                $0.1,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != .orderedSame
        }
        guard changes.count == 1, let change = changes.first else { return nil }
        let allowed = CharacterSet.letters.union(
            CharacterSet(charactersIn: "'’-")
        )
        guard change.0.unicodeScalars.allSatisfy(allowed.contains),
              change.1.unicodeScalars.allSatisfy(allowed.contains),
              spellingDistance(change.0.lowercased(), change.1.lowercased())
                  <= max(2, min(change.0.count, change.1.count) / 3) else {
            return nil
        }
        return (change.0, change.1)
    }

    nonisolated private static func spellingDistance(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous.last ?? 0
    }

    nonisolated private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: end).components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    nonisolated private static func percentile(
        _ percentile: Double,
        values: [Int]
    ) -> Int {
        guard !values.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(values.count))) - 1
        return values[min(values.count - 1, max(0, rank))]
    }

    private func setPhase(_ phase: DictationPhase) {
        self.phase = phase
        if phase != .error { errorMessage = nil }
        onPhaseChange?(phase)
    }

    private func scheduleIdle(delay: Duration = .seconds(1)) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.currentSession == nil, self.settings.isEnabled else { return }
            self.setPhase(.idle)
        }
    }
}

public typealias VoiceInteractionCoordinator = DictationCoordinator
