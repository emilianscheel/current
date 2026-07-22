import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var currentSession: DictationSession?
    public private(set) var lastTranscription = ""
    public private(set) var errorMessage: String?

    public let settings: SettingsStore
    public let model: ModelManager
    public let audio: AudioCaptureService
    public let insertion: InsertionService
    public let shortcut: ShortcutMonitor
    public var onPhaseChange: ((DictationPhase) -> Void)?
    private var maximumDurationTask: Task<Void, Never>?

    public init(
        settings: SettingsStore = .shared,
        model: ModelManager = ModelManager(),
        audio: AudioCaptureService = AudioCaptureService(),
        insertion: InsertionService = InsertionService(),
        shortcut: ShortcutMonitor = ShortcutMonitor()
    ) {
        self.settings = settings
        self.model = model
        self.audio = audio
        self.insertion = insertion
        self.shortcut = shortcut
        self.audio.selectedDeviceID = settings.inputDeviceID
        shortcut.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleShortcut(event) }
        }
    }

    public func startMonitoring() {
        guard settings.isEnabled else { setPhase(.paused); return }
        shortcut.holdThreshold = .milliseconds(settings.holdThresholdMilliseconds)
        shortcut.fallbackPreset = settings.fallbackShortcut
        do {
            try shortcut.start()
            setPhase(.idle)
        } catch {
            fail(error)
        }
    }

    public func stopMonitoring() {
        shortcut.stop()
        cancel()
        setPhase(.paused)
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
            _ = try? await insertion.insert(lastTranscription, trailingSpace: settings.trailingSpace, restoreClipboard: settings.restoreClipboard)
        }
    }

    public func clearLastTranscription() { lastTranscription = "" }

    public func cancel() {
        guard currentSession != nil else { return }
        maximumDurationTask?.cancel()
        currentSession = nil
        audio.cancel()
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
        Task { [weak self, transcription = model.transcription] in
            do {
                let text = try await transcription.transcribe(samples)
                guard let self, self.currentSession?.id == session.id else { return }
                self.setPhase(.inserting)
                let result = try await self.insertion.insert(
                    text,
                    trailingSpace: self.settings.trailingSpace,
                    restoreClipboard: self.settings.restoreClipboard
                )
                guard self.currentSession?.id == session.id else { return }
                self.lastTranscription = text
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
        currentSession = nil
        insertion.clearTarget()
        errorMessage = error.localizedDescription
        setPhase(.error)
        scheduleIdle(delay: .seconds(2.5))
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
