@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Observation

public struct ModelPreparationProgress: Sendable, Equatable {
    public let fractionCompleted: Double
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let stage: ModelDownloadStage

    public init(
        fractionCompleted: Double,
        downloadedBytes: Int64,
        totalBytes: Int64,
        stage: ModelDownloadStage
    ) {
        self.fractionCompleted = fractionCompleted
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.stage = stage
    }
}

public actor TranscriptionService {
    private var manager: AsrManager?
    private var loadedModels: AsrModels?
    private var partialManager: SlidingWindowAsrManager?
    private var partialUpdateTask: Task<Void, Never>?
    private let refinement: ContextualRefinementService

    public init(refinement: ContextualRefinementService = ContextualRefinementService()) {
        self.refinement = refinement
    }

    public func prepare(
        progress: (@Sendable (ModelPreparationProgress) -> Void)? = nil
    ) async throws {
        guard manager == nil else { return }
        let locations = ModelSnapshotLocations.current

        // FluidAudio's convenience loader checks for the expected model bundles,
        // while Current also rejects empty files and interrupted-download markers.
        // Force a clean retry when that stronger validation fails.
        if !ModelSnapshotValidator.isComplete(at: locations.snapshot) {
            _ = try await AsrModels.download(
                to: locations.snapshot,
                force: true,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { update in
                    let downloadedBytes = ModelIntegrity.directorySize(
                        at: locations.snapshot
                    )
                    let totalBytes = ModelSnapshotLocations
                        .approximateDownloadBytes
                    let byteFraction = totalBytes > 0
                        ? Double(downloadedBytes) / Double(totalBytes)
                        : update.fractionCompleted
                    let stage: ModelDownloadStage = switch update.phase {
                    case .listing: .listing
                    case .downloading: .downloading
                    case .compiling: .compiling
                    }
                    progress?(ModelPreparationProgress(
                        fractionCompleted: min(max(byteFraction, 0), 1),
                        downloadedBytes: downloadedBytes,
                        totalBytes: totalBytes,
                        stage: stage
                    ))
                }
            )
        }

        guard ModelSnapshotValidator.isComplete(at: locations.snapshot) else {
            throw CurrentError.modelUnavailable(
                "The model download is incomplete. Check your connection and retry."
            )
        }

        let models = try await AsrModels.load(
            from: locations.snapshot,
            version: .v3,
            encoderPrecision: .int8
        )
        let manager = AsrManager(models: models)
        loadedModels = models
        self.manager = manager
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw CurrentError.recordingTooShort }
        if manager == nil { try await prepare() }
        guard let manager else { throw CurrentError.modelUnavailable("The model did not load.") }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(_ request: DictationRequest) async throws -> TranscriptionCandidate {
        let rawText = try await transcribe(request.samples)
        return await refine(
            rawText: rawText,
            context: request.context,
            vocabulary: request.vocabulary
        )
    }

    public func refine(
        rawText: String,
        context: DictationContext,
        vocabulary: [LearnedVocabularyEntry] = []
    ) async -> TranscriptionCandidate {
        let deterministic = DeterministicRefiner.refine(
            rawText,
            context: context,
            vocabulary: vocabulary
        )
        let refined = await refinement.refine(
            deterministic: deterministic,
            rawText: rawText,
            context: context
        )
        return TranscriptionCandidate(rawText: rawText, refinement: refined)
    }

    public func prewarmRefinement() async {
        await refinement.prewarm()
    }

    public func editSelection(
        _ selection: String,
        instruction: String,
        context: DictationContext
    ) async -> RefinementResult? {
        await refinement.edit(
            selection: selection,
            instruction: instruction,
            context: context
        )
    }

    public func startPartialTranscription(
        onUpdate: @escaping @Sendable (String) -> Void
    ) async {
        await stopPartialTranscription()
        guard let loadedModels else { return }
        do {
            let partialManager = SlidingWindowAsrManager()
            try await partialManager.loadModels(loadedModels)
            try await partialManager.startStreaming(source: .microphone)
            self.partialManager = partialManager
            partialUpdateTask = Task {
                let updates = await partialManager.transcriptionUpdates
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    let confirmed = await partialManager.confirmedTranscript
                    let preview = [confirmed, update.text]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    onUpdate(preview)
                }
            }
        } catch {
            partialManager = nil
            partialUpdateTask = nil
        }
    }

    public func consumePartialSamples(_ samples: [Float]) async {
        guard let partialManager,
              !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?.pointee else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        await partialManager.streamAudio(buffer)
    }

    public func stopPartialTranscription() async {
        partialUpdateTask?.cancel()
        partialUpdateTask = nil
        if let partialManager {
            await partialManager.cancel()
        }
        partialManager = nil
    }

    public func unload() async {
        await stopPartialTranscription()
        manager = nil
        loadedModels = nil
    }

    public nonisolated func verifyInstalledModel() throws {
        let locations = ModelSnapshotLocations.current
        guard ModelSnapshotValidator.isComplete(at: locations.snapshot) else {
            throw CurrentError.modelUnavailable("The downloaded snapshot is incomplete; retry the download.")
        }
        try ModelIntegrity.verifyOrCreateManifest(
            for: locations.snapshot,
            manifestURL: locations.integrityManifest
        )
    }

    public nonisolated func removeLegacyModelIfReplacementReady() {
        LegacyModelCleanup.removeIfReplacementReady(
            true,
            locations: ModelSnapshotLocations.legacy
        )
    }
}

public struct ModelSnapshotLocations: Sendable {
    /// Expected size of the pinned Parakeet TDT v3 INT8 artifact. FluidAudio
    /// reports progress per Core ML component, so the aggregate on-disk byte
    /// count is the stable source of truth for Current's overall progress.
    public static let approximateDownloadBytes: Int64 = 483_000_000

    public let models: URL
    public let snapshot: URL
    public let integrityManifest: URL

    public static var current: ModelSnapshotLocations {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let models = support.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        return ModelSnapshotLocations(
            models: models,
            snapshot: models.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true),
            integrityManifest: models.appendingPathComponent("parakeet-tdt-v3-integrity.json")
        )
    }

    public static var legacy: ModelSnapshotLocations {
        let current = current
        return ModelSnapshotLocations(
            models: current.models,
            snapshot: current.models.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true),
            integrityManifest: current.models.appendingPathComponent("parakeet-unified-integrity.json")
        )
    }
}

public enum ModelSnapshotValidator {
    public static let requiredFiles = [
        "Preprocessor.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/coremldata.bin",
        "Decoder.mlmodelc/coremldata.bin",
        "JointDecisionv3.mlmodelc/coremldata.bin",
        "parakeet_vocab.json",
    ]

    public static func isComplete(at snapshot: URL) -> Bool {
        let fileManager = FileManager.default
        guard requiredFiles.allSatisfy({ relativePath in
            var isDirectory: ObjCBool = false
            let path = snapshot.appendingPathComponent(relativePath).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && ((try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }) else { return false }

        guard let enumerator = fileManager.enumerator(
            at: snapshot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return !enumerator.contains { item in
            guard let url = item as? URL else { return false }
            return url.pathExtension == "partial" || url.lastPathComponent.hasSuffix(".partial.etag")
        }
    }
}

public enum LegacyModelCleanup {
    public static func removeIfReplacementReady(
        _ replacementReady: Bool,
        locations: ModelSnapshotLocations,
        fileManager: FileManager = .default
    ) {
        guard replacementReady else { return }
        for url in [locations.snapshot, locations.integrityManifest]
        where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
@Observable
public final class ModelManager {
    public private(set) var state: ModelState = .notInstalled
    public private(set) var downloadMetrics: ModelDownloadMetrics?
    public private(set) var lastLoadDuration: Duration?
    public let transcription: TranscriptionService
    private var preparationTask: Task<Void, Never>?
    private var speedExpiryTask: Task<Void, Never>?
    private var metricsTracker = ModelDownloadMetricsTracker()
    private var acceptsDownloadProgress = false
    private var preparationGeneration = UUID()

    public init(transcription: TranscriptionService = TranscriptionService()) {
        self.transcription = transcription
    }

    public var hasInstalledSnapshot: Bool {
        ModelSnapshotValidator.isComplete(at: ModelSnapshotLocations.current.snapshot)
    }

    public var downloadedSizeBytes: Int64 {
        ModelIntegrity.directorySize(
            at: ModelSnapshotLocations.current.snapshot
        )
    }

    public func prepareIfNeeded() {
        guard preparationTask == nil, !state.isReady else { return }
        let generation = UUID()
        preparationGeneration = generation
        metricsTracker.reset()
        downloadMetrics = metricsTracker.update(
            fractionCompleted: 0,
            downloadedBytes: 0,
            totalBytes: ModelSnapshotLocations.approximateDownloadBytes,
            stage: .listing
        )
        state = .downloading(progress: 0)
        acceptsDownloadProgress = true
        let clock = ContinuousClock()
        preparationTask = Task { [weak self, transcription] in
            guard let self else { return }
            let start = clock.now
            do {
                try await transcription.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyDownloadProgress(
                            progress,
                            generation: generation
                        )
                    }
                }
                guard !Task.isCancelled,
                      preparationGeneration == generation else { return }
                acceptsDownloadProgress = false
                expireDownloadSpeed()
                state = .verifying
                try transcription.verifyInstalledModel()
                transcription.removeLegacyModelIfReplacementReady()
                lastLoadDuration = start.duration(to: clock.now)
                state = .ready
            } catch {
                guard preparationGeneration == generation else { return }
                acceptsDownloadProgress = false
                expireDownloadSpeed()
                state = .failed(error.localizedDescription)
            }
            if preparationGeneration == generation {
                preparationTask = nil
            }
        }
    }

    public func retry() {
        preparationGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        acceptsDownloadProgress = false
        speedExpiryTask?.cancel()
        speedExpiryTask = nil
        metricsTracker.reset()
        downloadMetrics = nil
        state = .notInstalled
        prepareIfNeeded()
    }

    public func unload() async {
        preparationGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        acceptsDownloadProgress = false
        speedExpiryTask?.cancel()
        speedExpiryTask = nil
        metricsTracker.reset()
        downloadMetrics = nil
        await transcription.unload()
        state = .notInstalled
    }

    private func applyDownloadProgress(
        _ progress: ModelPreparationProgress,
        generation: UUID
    ) {
        guard acceptsDownloadProgress,
              preparationGeneration == generation else { return }
        let metrics = metricsTracker.update(
            fractionCompleted: progress.fractionCompleted,
            downloadedBytes: progress.downloadedBytes,
            totalBytes: progress.totalBytes,
            stage: progress.stage
        )
        downloadMetrics = metrics
        state = .downloading(progress: metrics.fractionCompleted)
        scheduleSpeedExpiry(for: metrics)
    }

    private func scheduleSpeedExpiry(for metrics: ModelDownloadMetrics) {
        speedExpiryTask?.cancel()
        guard metrics.bytesPerSecond != nil else { return }
        let downloadedBytes = metrics.downloadedBytes
        speedExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  let self,
                  self.downloadMetrics?.downloadedBytes == downloadedBytes else {
                return
            }
            self.expireDownloadSpeed()
        }
    }

    private func expireDownloadSpeed() {
        speedExpiryTask?.cancel()
        speedExpiryTask = nil
        downloadMetrics = downloadMetrics?.hidingSpeed()
    }

    public func removeDownloadedModel() async throws {
        await unload()
        let locations = ModelSnapshotLocations.current
        if FileManager.default.fileExists(atPath: locations.snapshot.path) {
            try FileManager.default.removeItem(at: locations.snapshot)
        }
        if FileManager.default.fileExists(atPath: locations.integrityManifest.path) {
            try FileManager.default.removeItem(at: locations.integrityManifest)
        }
    }
}

public enum ModelIntegrity {
    public static func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? 0
            )
        }
        return total
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyOrCreateManifest(for directory: URL, manifestURL: URL) throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .map { directory.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
            .sorted { $0.path < $1.path }
        var current: [String: String] = [:]
        for file in files {
            current[String(file.path.dropFirst(directory.path.count + 1))] = try sha256(of: file)
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
            guard expected == current else { throw CurrentError.modelUnavailable("Model checksum verification failed; retry the download.") }
        } else {
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(current)
            try data.write(to: manifestURL, options: .atomic)
        }
    }
}
