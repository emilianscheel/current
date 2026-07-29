import CoreGraphics
import Foundation

public enum ContextWorkerProtocolVersion {
    public static let current = 4
    public static let serviceName = "local.Current.ContextWorker"
}

@objc public protocol ContextWorkerXPCProtocol {
    func handshake(withReply reply: @escaping (Int, Int32) -> Void)
    func recognizeText(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func structureContext(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func generatePrompt(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func prepareIntentModel(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func classifyIntent(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func cancelRequest(_ requestData: Data, withReply reply: @escaping () -> Void)
    func cancelBackgroundWork(withReply reply: @escaping () -> Void)
    func cancelAll(withReply reply: @escaping () -> Void)
    func unload(withReply reply: @escaping () -> Void)
}

public enum ContextWorkerRequestPriority: String, Codable, Sendable, Equatable {
    case background
    case interactive
    case voiceRouting
}

public struct ContextWorkerModelPreparationRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelSnapshotPath: String
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID = UUID(),
        modelSnapshotPath: String,
        priority: ContextWorkerRequestPriority = .voiceRouting
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.priority = priority
    }
}

public struct ContextWorkerIntentRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelSnapshotPath: String
    public let routingRequest: IntentRoutingRequest
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID,
        modelSnapshotPath: String,
        routingRequest: IntentRoutingRequest,
        priority: ContextWorkerRequestPriority = .voiceRouting
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.routingRequest = routingRequest
        self.priority = priority
    }
}

public struct ContextWorkerCancellationRequest: Codable, Sendable {
    public let requestID: UUID

    public init(requestID: UUID) {
        self.requestID = requestID
    }
}

public struct ContextWorkerOCRRequest: Codable, Sendable {
    public let requestID: UUID
    public let image: ContextWorkerImagePayload
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID = UUID(),
        image: ContextWorkerImagePayload,
        priority: ContextWorkerRequestPriority = .background
    ) {
        self.requestID = requestID
        self.image = image
        self.priority = priority
    }
}

public struct ContextWorkerStructureRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelSnapshotPath: String
    public let currentState: String
    public let observations: [ContextObservation]
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID = UUID(),
        modelSnapshotPath: String,
        currentState: String,
        observations: [ContextObservation],
        priority: ContextWorkerRequestPriority = .background
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.currentState = currentState
        self.observations = observations
        self.priority = priority
    }
}

public struct ContextWorkerPromptRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelSnapshotPath: String
    public let envelope: PromptContextEnvelope
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID = UUID(),
        modelSnapshotPath: String,
        envelope: PromptContextEnvelope,
        priority: ContextWorkerRequestPriority = .interactive
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.envelope = envelope
        self.priority = priority
    }
}

@MainActor
public final class ContextWorkerClient: @unchecked Sendable {
    public var onStateChange: (@MainActor (ContextBackgroundState) -> Void)?
    public private(set) var processIdentifier: pid_t?

    private var connection: NSXPCConnection?
    private var handshakeComplete = false
    private var consecutiveFailures = 0
    private var retainsGemmaForIntentRouting = false
    private var routingReleaseTask: Task<Void, Never>?

    public init() {}

    public func recognizeText(
        image: ContextWorkerImagePayload,
        priority: ContextWorkerRequestPriority = .background
    ) async throws -> [ContextTextBlock] {
        let payload = ContextWorkerOCRRequest(
            image: image,
            priority: priority
        )
        let response = try await request(
            method: { proxy, data, reply in
                proxy.recognizeText(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
        return try JSONDecoder().decode(
            [ContextTextBlock].self,
            from: response
        )
    }

    public func structure(
        snapshot: URL,
        currentState: String,
        observations: [ContextObservation]
    ) async throws -> ContextDocumentUpdate {
        let payload = ContextWorkerStructureRequest(
            modelSnapshotPath: snapshot.path,
            currentState: currentState,
            observations: observations
        )
        let response = try await request(
            method: { proxy, data, reply in
                proxy.structureContext(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
        return try JSONDecoder().decode(
            ContextDocumentUpdate.self,
            from: response
        )
    }

    public func generatePrompt(
        snapshot: URL,
        envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        let payload = ContextWorkerPromptRequest(
            modelSnapshotPath: snapshot.path,
            envelope: envelope
        )
        let response = try await request(
            method: { proxy, data, reply in
                proxy.generatePrompt(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
        return try JSONDecoder().decode(
            PromptGenerationDisposition.self,
            from: response
        )
    }

    public func setIntentRoutingEnabled(
        _ enabled: Bool,
        snapshot: URL
    ) async throws {
        let wasRetained = retainsGemmaForIntentRouting
        retainsGemmaForIntentRouting = enabled
        routingReleaseTask?.cancel()
        routingReleaseTask = nil
        guard enabled else {
            if wasRetained {
                routingReleaseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5 * 60))
                    guard !Task.isCancelled else { return }
                    await self?.unload()
                }
            }
            return
        }
        let payload = ContextWorkerModelPreparationRequest(
            modelSnapshotPath: snapshot.path
        )
        _ = try await request(
            method: { proxy, data, reply in
                proxy.prepareIntentModel(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
    }

    public func classifyIntent(
        snapshot: URL,
        request routingRequest: IntentRoutingRequest,
        requestID: UUID
    ) async throws -> IntentDecision {
        let payload = ContextWorkerIntentRequest(
            requestID: requestID,
            modelSnapshotPath: snapshot.path,
            routingRequest: routingRequest
        )
        let response = try await request(
            method: { proxy, data, reply in
                proxy.classifyIntent(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
        return try JSONDecoder().decode(IntentDecision.self, from: response)
    }

    public func cancel(requestID: UUID) async {
        guard connection != nil, let proxy = try? await proxy(),
              let data = try? JSONEncoder().encode(
                  ContextWorkerCancellationRequest(requestID: requestID)
              ) else { return }
        await withCheckedContinuation { continuation in
            proxy.cancelRequest(data) { continuation.resume() }
        }
    }

    public func cancelBackgroundWork() async {
        guard connection != nil, let proxy = try? await proxy() else { return }
        await withCheckedContinuation { continuation in
            proxy.cancelBackgroundWork { continuation.resume() }
        }
    }

    public func cancelAll() async {
        guard connection != nil else { return }
        guard let proxy = try? await proxy() else { return }
        await withCheckedContinuation { continuation in
            proxy.cancelAll {
                continuation.resume()
            }
        }
    }

    public func unload(force: Bool = false) async {
        guard force || !retainsGemmaForIntentRouting else { return }
        guard connection != nil else { return }
        guard let proxy = try? await proxy() else {
            invalidate()
            return
        }
        await withCheckedContinuation { continuation in
            proxy.unload {
                continuation.resume()
            }
        }
        invalidate()
    }

    public func invalidate() {
        routingReleaseTask?.cancel()
        routingReleaseTask = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        handshakeComplete = false
        processIdentifier = nil
        onStateChange?(.idle)
    }

    private func request<Payload: Encodable>(
        method: @escaping (
            ContextWorkerXPCProtocol,
            Data,
            @escaping (Data?, String?) -> Void
        ) -> Void,
        payload: Payload,
        requestID: UUID
    ) async throws -> Data {
        let encoded = try JSONEncoder().encode(payload)
        return try await withTaskCancellationHandler {
            var lastError: Error?
            for attempt in 0..<2 {
                try Task.checkCancellation()
                do {
                    let proxy = try await proxy()
                    let result = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Data, Error>) in
                        method(proxy, encoded) { data, errorMessage in
                            if let data {
                                continuation.resume(returning: data)
                            } else {
                                continuation.resume(
                                    throwing: CurrentError.modelUnavailable(
                                        errorMessage
                                            ?? "The context worker returned no data."
                                    )
                                )
                            }
                        }
                    }
                    try Task.checkCancellation()
                    consecutiveFailures = 0
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = error
                    invalidate()
                    if attempt == 0 { continue }
                }
            }
            consecutiveFailures += 1
            onStateChange?(.degraded)
            throw lastError ?? CurrentError.modelUnavailable(
                "The context worker is unavailable."
            )
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancel(requestID: requestID)
            }
        }
    }

    private func proxy() async throws -> ContextWorkerXPCProtocol {
        if connection == nil {
            let connection = NSXPCConnection(
                serviceName: ContextWorkerProtocolVersion.serviceName
            )
            connection.remoteObjectInterface = NSXPCInterface(
                with: ContextWorkerXPCProtocol.self
            )
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handshakeComplete = false
                    self?.processIdentifier = nil
                    self?.onStateChange?(.degraded)
                }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.connection = nil
                    self?.handshakeComplete = false
                    self?.processIdentifier = nil
                }
            }
            connection.resume()
            self.connection = connection
        }
        guard let connection,
              let proxy = connection.remoteObjectProxyWithErrorHandler({
                  [weak self] _ in
                  Task { @MainActor [weak self] in
                      self?.handshakeComplete = false
                      self?.processIdentifier = nil
                      self?.onStateChange?(.degraded)
                  }
              }) as? ContextWorkerXPCProtocol else {
            throw CurrentError.modelUnavailable(
                "Could not connect to the context worker."
            )
        }
        if !handshakeComplete {
            let handshake = await withCheckedContinuation { continuation in
                proxy.handshake { version, processIdentifier in
                    continuation.resume(
                        returning: (version, processIdentifier)
                    )
                }
            }
            guard handshake.0 == ContextWorkerProtocolVersion.current else {
                invalidate()
                throw CurrentError.modelUnavailable(
                    "The context worker version does not match Current."
                )
            }
            processIdentifier = pid_t(handshake.1)
            handshakeComplete = true
        }
        return proxy
    }
}

public actor XPCVisionOCRProvider: InteractiveOCRProviding {
    private let client: ContextWorkerClient

    public init(client: ContextWorkerClient) {
        self.client = client
    }

    public func recognizeText(
        in image: CGImage
    ) async throws -> [ContextTextBlock] {
        let payload = try await Task.detached(priority: .background) {
            try ContextWorkerImagePayload(image: image)
        }.value
        return try await client.recognizeText(image: payload)
    }

    public func recognizeTextInteractively(
        in image: CGImage
    ) async throws -> [ContextTextBlock] {
        let payload = try await Task.detached(priority: .userInitiated) {
            try ContextWorkerImagePayload(image: image)
        }.value
        return try await client.recognizeText(
            image: payload,
            priority: .interactive
        )
    }
}

public actor XPCGemmaPromptProvider: PromptResponseGenerating {
    private let client: ContextWorkerClient
    private let snapshot: URL

    public init(
        client: ContextWorkerClient,
        snapshot: URL = GemmaModelLocations.current.snapshot
    ) {
        self.client = client
        self.snapshot = snapshot
    }

    public func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        try await client.generatePrompt(snapshot: snapshot, envelope: envelope)
    }
}

public actor GemmaVoiceIntentRouter: VoiceIntentRoutingProviding {
    private let client: ContextWorkerClient
    private let snapshot: URL
    private var enabled = false

    public init(
        client: ContextWorkerClient,
        snapshot: URL = GemmaModelLocations.current.snapshot
    ) {
        self.client = client
        self.snapshot = snapshot
    }

    public func isAvailable() -> Bool {
        GemmaModelValidator.isComplete()
    }

    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        guard isAvailable() else { return }
        try? await client.setIntentRoutingEnabled(enabled, snapshot: snapshot)
    }

    public func prepare(
        sessionID: UUID,
        context: IntentRoutingContext
    ) async {
        guard enabled || isAvailable() else { return }
        try? await client.setIntentRoutingEnabled(true, snapshot: snapshot)
    }

    public func classify(
        _ request: IntentRoutingRequest,
        sessionID: UUID
    ) async throws -> IntentDecision {
        guard isAvailable() else {
            throw CurrentError.modelUnavailable(
                "Gemma intent routing is unavailable."
            )
        }
        return try await client.classifyIntent(
            snapshot: snapshot,
            request: request,
            requestID: sessionID
        )
    }

    public func cancel(sessionID: UUID) async {
        await client.cancel(requestID: sessionID)
    }
}

public actor XPCContextStructuringProvider: ContextStructuringProviding {
    private let client: ContextWorkerClient
    private let snapshot: URL

    public init(
        client: ContextWorkerClient,
        snapshot: URL = GemmaModelLocations.current.snapshot
    ) {
        self.client = client
        self.snapshot = snapshot
    }

    public func updateContextDocument(
        currentState: String,
        observations: [ContextObservation]
    ) async throws -> ContextDocumentUpdate {
        try await client.structure(
            snapshot: snapshot,
            currentState: currentState,
            observations: observations
        )
    }
}

private extension ContextWorkerImagePayload {
    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = Data(count: bytesPerRow * height)
        guard bytes.count <= Self.maximumByteCount else {
            throw CurrentError.modelUnavailable(
                "The context screenshot exceeds the worker payload limit."
            )
        }
        let rendered = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw CurrentError.modelUnavailable(
                "Could not prepare the context screenshot for the worker."
            )
        }
        try self.init(
            bgraData: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}
