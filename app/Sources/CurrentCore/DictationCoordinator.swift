import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class DictationCoordinator {
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
        promptContextPreparer: (any PromptContextPreparing)? = nil
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
                Task { [intentRouter, context = insertion.currentContext] in
                    await intentRouter.prepare(
                        sessionID: session.id,
                        context: IntentRoutingContext(context: context)
                    )
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
                    let decision = try await self.intentRouter.classify(
                        IntentRoutingRequest(
                            transcript: rawText,
                            context: context
                        ),
                        sessionID: session.id
                    )
                    guard self.isCurrent(
                        sessionID: session.id,
                        generation: generation
                    ) else { return }
                    directDictation = decision.intent == .direct
                    switch decision.intent {
                    case .prompt:
                        let envelope: PromptContextEnvelope
                        self.pendingPromptBypass = PendingPromptBypass(
                            session: session,
                            rawText: rawText,
                            context: context,
                            captureTarget: captureTarget
                        )
                        self.shortcut.setReturnInterceptionEnabled(true)
                        self.setPhase(.gatheringContext)
                        if let preparer = self.promptContextPreparer {
                            envelope = try await preparer.prepare(
                                instruction: rawText,
                                focusedContext: context,
                                target: captureTarget,
                                continuousContextEnabled:
                                    self.settings.continuousContextEnabled
                            )
                        } else if let contextRepository = self.contextRepository {
                            envelope = await contextRepository.promptContext(
                                instruction: rawText,
                                focusedContext: context,
                                target: captureTarget,
                                includeApplicationContext:
                                    self.settings.continuousContextEnabled
                            )
                        } else {
                            envelope = PromptContextEnvelope(
                                instruction: rawText,
                                focusedContext: context,
                                sections: []
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
                        let disposition = try await self.intelligence
                            .generatePromptDisposition(envelope)
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
                let targetProcessIdentifier = self.insertion.targetApplicationPresentation?.processIdentifier
                let result = try await self.insertion.insert(
                    text,
                    context: context,
                    restoreClipboard: true
                )
                guard self.isCurrent(sessionID: session.id, generation: generation) else {
                    return
                }
                self.completeInsertion(
                    text: text,
                    session: session,
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
                self.completeInsertion(
                    text: pendingPromptBypass.rawText,
                    session: pendingPromptBypass.session,
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
        captureTarget: ContextCaptureTarget?,
        targetProcessIdentifier: pid_t?,
        result: InsertionService.Result
    ) {
        clearPromptBypass()
        lastTranscription = text
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        onTranscriptionCompleted?(Date())
        if Self.shouldRecordContext(
            targetProcessIdentifier: targetProcessIdentifier,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ) {
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
