import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var currentSession: DictationSession?
    public private(set) var lastTranscription = ""
    public private(set) var partialTranscription = ""
    public private(set) var errorMessage: String?

    public let settings: SettingsStore
    public let model: ModelManager
    public let audio: AudioCaptureService
    public let insertion: InsertionService
    public let shortcut: ShortcutMonitor
    public let vocabulary: LearnedVocabularyStore
    public let intelligence: any LocalIntelligenceProviding
    public let contextRepository: ContextRepository?
    public var onPhaseChange: ((DictationPhase) -> Void)?
    public var onPartialTranscriptionChange: ((String) -> Void)?
    public var onSuccessfulTranscription: ((String, Date) -> Void)?
    public var onMonitoringChange: ((Bool) -> Void)?
    private var maximumDurationTask: Task<Void, Never>?

    public init(
        settings: SettingsStore = .shared,
        model: ModelManager = ModelManager(),
        audio: AudioCaptureService = AudioCaptureService(),
        insertion: InsertionService = InsertionService(),
        shortcut: ShortcutMonitor = ShortcutMonitor(),
        vocabulary: LearnedVocabularyStore = LearnedVocabularyStore(),
        intelligence: any LocalIntelligenceProviding = AppleFoundationModelProvider(),
        contextRepository: ContextRepository? = nil
    ) {
        self.settings = settings
        self.model = model
        self.audio = audio
        self.insertion = insertion
        self.shortcut = shortcut
        self.vocabulary = vocabulary
        self.intelligence = intelligence
        self.contextRepository = contextRepository
        self.audio.selectedDeviceID = settings.inputDeviceID
        shortcut.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleShortcut(event) }
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
    }

    public func toggleEnabled() {
        settings.isEnabled.toggle()
        settings.isEnabled ? startMonitoring() : stopMonitoring()
    }

    public func beginFromMenu() {
        guard phase == .idle || phase == .success || phase == .error else { stopAndTranscribe(); return }
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
            _ = try? await insertion.insert(
                lastTranscription,
                context: insertion.currentContext,
                restoreClipboard: true
            )
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
        maximumDurationTask?.cancel()
        currentSession = nil
        audio.cancel()
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        Task { await model.transcription.stopPartialTranscription() }
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
            let session = DictationSession()
            if phase != .armed { insertion.captureTarget() }
            currentSession = session
            try audio.start()
            let transcription = model.transcription
            audio.setSampleHandler { samples in
                Task { await transcription.consumePartialSamples(samples) }
            }
            Task { [weak self] in
                await transcription.prewarmRefinement()
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
        guard let session = currentSession else { return }
        maximumDurationTask?.cancel()
        let samples = audio.stop()
        let minimumSamples = Int(settings.minimumRecordingDuration * 16_000)
        guard samples.count >= minimumSamples else {
            currentSession = nil
            insertion.clearTarget()
            fail(CurrentError.recordingTooShort)
            return
        }
        setPhase(.transcribing)
        let context = insertion.currentContext
        let vocabularyEntries = vocabulary.entries
        Task { [weak self, transcription = model.transcription] in
            do {
                await transcription.stopPartialTranscription()
                let rawText = try await transcription.transcribe(samples)
                guard let self, self.currentSession?.id == session.id else { return }
                self.setPhase(.classifying)
                let decision = await self.intelligence.classifyIntent(
                    VoiceInteractionRequest(
                        transcript: rawText,
                        context: context
                    )
                )
                guard self.currentSession?.id == session.id else { return }
                let text: String
                if decision.effectiveIntent == .prompt {
                    self.setPhase(.generating)
                    let envelope: PromptContextEnvelope
                    if let contextRepository = self.contextRepository {
                        envelope = await contextRepository.promptContext(
                            instruction: rawText,
                            focusedContext: context
                        )
                    } else {
                        envelope = PromptContextEnvelope(
                            instruction: rawText,
                            focusedContext: context,
                            targetApplicationContext: "",
                            otherVisibleApplicationContexts: []
                        )
                    }
                    text = try await self.intelligence
                        .generatePromptResponse(envelope)
                        .text
                } else {
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
                }
                guard self.currentSession?.id == session.id else { return }
                if decision.effectiveIntent == .direct,
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
                self.setPhase(.inserting)
                let targetProcessIdentifier = self.insertion.targetApplicationPresentation?.processIdentifier
                let result = try await self.insertion.insert(
                    text,
                    context: context,
                    restoreClipboard: true
                )
                guard self.currentSession?.id == session.id else { return }
                self.lastTranscription = text
                self.partialTranscription = ""
                self.onPartialTranscriptionChange?("")
                if Self.shouldRecordContext(
                    targetProcessIdentifier: targetProcessIdentifier,
                    currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
                ) {
                    self.onSuccessfulTranscription?(text, session.startedAt)
                }
                self.currentSession = nil
                if result == .copied { self.errorMessage = "Copied — paste manually." }
                self.setPhase(result == .copied ? .error : .success)
                self.scheduleIdle()
            } catch {
                guard let self, self.currentSession?.id == session.id else { return }
                self.currentSession = nil
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        audio.cancel()
        partialTranscription = ""
        onPartialTranscriptionChange?("")
        Task { await model.transcription.stopPartialTranscription() }
        currentSession = nil
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

    nonisolated public static func looksLikeUnsupportedEditInstruction(
        _ text: String
    ) -> Bool {
        let normalized = text.lowercased()
        return [
            "fix grammar", "make it shorter", "shorten", "rewrite", "translate",
            "make professional", "make casual", "abbreviate", "summarize",
        ].contains { normalized.contains($0) }
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
