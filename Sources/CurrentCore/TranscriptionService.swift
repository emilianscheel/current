import CryptoKit
import FluidAudio
import Foundation
import Observation

public actor TranscriptionService {
    private var manager: UnifiedAsrManager?

    public init() {}

    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        let locations = ModelSnapshotLocations.current

        // FluidAudio's convenience loader considers an encoder directory to be
        // cached as soon as the directory exists. Interrupted downloads leave
        // that directory behind with a resumable `weight.bin.partial`, so make
        // the stronger completeness check here and explicitly resume first.
        if !ModelSnapshotValidator.isComplete(at: locations.snapshot) {
            try await ModelHub.download(
                .parakeetUnified,
                to: locations.models,
                variant: "offline"
            ) { update in
                progress?(update.fractionCompleted)
            }
        }

        guard ModelSnapshotValidator.isComplete(at: locations.snapshot) else {
            throw CurrentError.modelUnavailable(
                "The model download is incomplete. Check your connection and retry."
            )
        }

        let manager = UnifiedAsrManager(encoderPrecision: .int8)
        try await manager.loadModels(from: locations.snapshot)
        self.manager = manager
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw CurrentError.recordingTooShort }
        if manager == nil { try await prepare() }
        guard let manager else { throw CurrentError.modelUnavailable("The model did not load.") }
        let result = try await manager.transcribe(samples)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unload() { manager = nil }

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
}

public struct ModelSnapshotLocations: Sendable {
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
            snapshot: models.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true),
            integrityManifest: models.appendingPathComponent("parakeet-unified-integrity.json")
        )
    }
}

public enum ModelSnapshotValidator {
    private static let requiredFiles = [
        "parakeet_unified_encoder_int8.mlmodelc/coremldata.bin",
        "parakeet_unified_decoder.mlmodelc/coremldata.bin",
        "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
        "vocab.json",
        "metadata.json",
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

@MainActor
@Observable
public final class ModelManager {
    public private(set) var state: ModelState = .notInstalled
    public private(set) var lastLoadDuration: Duration?
    public let transcription: TranscriptionService
    private var preparationTask: Task<Void, Never>?

    public init(transcription: TranscriptionService = TranscriptionService()) {
        self.transcription = transcription
    }

    public var hasInstalledSnapshot: Bool {
        ModelSnapshotValidator.isComplete(at: ModelSnapshotLocations.current.snapshot)
    }

    public func prepareIfNeeded() {
        guard preparationTask == nil, !state.isReady else { return }
        state = .downloading(progress: 0.01)
        let clock = ContinuousClock()
        preparationTask = Task { [weak self, transcription] in
            guard let self else { return }
            let start = clock.now
            do {
                try await transcription.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in self?.state = .downloading(progress: progress) }
                }
                guard !Task.isCancelled else { return }
                state = .verifying
                try transcription.verifyInstalledModel()
                lastLoadDuration = start.duration(to: clock.now)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
            preparationTask = nil
        }
    }

    public func retry() {
        preparationTask?.cancel()
        preparationTask = nil
        state = .notInstalled
        prepareIfNeeded()
    }

    public func unload() async {
        preparationTask?.cancel()
        preparationTask = nil
        await transcription.unload()
        state = .notInstalled
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
