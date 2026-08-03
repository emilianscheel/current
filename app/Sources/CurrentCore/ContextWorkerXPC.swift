import CoreGraphics
import Foundation
import OSLog

public enum ContextWorkerProtocolVersion {
    public static let current = 6
    public static let serviceName = "com.emilianscheel.current.ContextWorker"
}

@objc public protocol ContextWorkerXPCProtocol {
    func handshake(withReply reply: @escaping (Int, Int32) -> Void)
    func recognizeText(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func structureContext(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func generatePrompt(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func prepareIntentModel(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func classifyIntent(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func cancelRequest(_ requestData: Data, withReply reply: @escaping () -> Void)
    func cancelBackgroundWork(withReply reply: @escaping () -> Void)
    func cancelAll(withReply reply: @escaping () -> Void)
    func unload(withReply reply: @escaping () -> Void)
}

public enum ContextWorkerReply: Codable, Sendable, Equatable {
    case success(Data)
    case cancelled
    case failure(String)
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
    public let generationRequest: PromptGenerationRequest
    public let priority: ContextWorkerRequestPriority

    public init(
        requestID: UUID = UUID(),
        modelSnapshotPath: String,
        generationRequest: PromptGenerationRequest,
        priority: ContextWorkerRequestPriority = .interactive
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.generationRequest = generationRequest
        self.priority = priority
    }
}

private enum ContextWorkerTransportError: LocalizedError, Sendable {
    case disconnected(String, generation: UUID?)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .disconnected(let message, _): message
        case .timeout(let operation):
            "The context worker timed out while performing \(operation)."
        }
    }
}

private final class ContextWorkerCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: sending Result<Value, Error>) -> Bool {
        let (continuation, timeoutTask) = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            let timeout = self.timeoutTask
            self.timeoutTask = nil
            return (current, timeout)
        }
        guard let continuation else { return false }
        timeoutTask?.cancel()
        continuation.resume(with: result)
        return true
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard continuation != nil else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }
}

private final class ContextWorkerPendingInvocation: @unchecked Sendable {
    let requestID: UUID?
    private let failClosure: @Sendable (Error) -> Void

    init(
        requestID: UUID?,
        fail: @escaping @Sendable (Error) -> Void
    ) {
        self.requestID = requestID
        failClosure = fail
    }

    func fail(_ error: Error) { failClosure(error) }
}

@MainActor
public final class ContextWorkerClient: @unchecked Sendable {
    public var onStateChange: (@MainActor (ContextBackgroundState) -> Void)?
    public private(set) var processIdentifier: pid_t?

    nonisolated private static let logger = Logger(
        subsystem: "com.emilianscheel.current",
        category: "ContextWorkerClient"
    )
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var handshakeComplete = false
    private var handshakeTask: Task<(Int, Int32), Error>?
    private var consecutiveFailures = 0
    private var retainsGemmaForIntentRouting = false
    private var routingReleaseTask: Task<Void, Never>?
    private var pendingInvocations: [UUID: ContextWorkerPendingInvocation] = [:]
    private let connectionFactory: @MainActor () -> NSXPCConnection

    public init() {
        connectionFactory = {
            NSXPCConnection(
                serviceName: ContextWorkerProtocolVersion.serviceName
            )
        }
    }

    package init(
        connectionFactory: @escaping @MainActor () -> NSXPCConnection
    ) {
        self.connectionFactory = connectionFactory
    }

    public func recognizeText(
        image: ContextWorkerImagePayload,
        priority: ContextWorkerRequestPriority = .background
    ) async throws -> [ContextTextBlock] {
        let payload = ContextWorkerOCRRequest(
            image: image,
            priority: priority
        )
        let response = try await request(
            operation: "ocr",
            timeout: .seconds(30),
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
            operation: "structure",
            timeout: .seconds(120),
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
        request generationRequest: PromptGenerationRequest
    ) async throws -> PromptGenerationDisposition {
        let payload = ContextWorkerPromptRequest(
            modelSnapshotPath: snapshot.path,
            generationRequest: generationRequest
        )
        let response = try await request(
            operation: "prompt",
            timeout: .seconds(120),
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
            operation: "prepare-intent",
            timeout: .seconds(120),
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
            operation: "classify-intent",
            timeout: .seconds(10),
            method: { proxy, data, reply in
                proxy.classifyIntent(data, withReply: reply)
            },
            payload: payload,
            requestID: payload.requestID
        )
        return try JSONDecoder().decode(IntentDecision.self, from: response)
    }

    public func cancel(requestID: UUID) async {
        cancelPendingRequest(requestID)
        await cancelRemoteRequest(requestID)
    }

    private func cancelRemoteRequest(_ requestID: UUID) async {
        guard connection != nil,
              let data = try? JSONEncoder().encode(
                  ContextWorkerCancellationRequest(requestID: requestID)
              ) else { return }
        _ = try? await performVoidInvocation(
            operation: "cancel-request",
            timeout: .seconds(5)
        ) { proxy, reply in proxy.cancelRequest(data, withReply: reply) }
    }

    public func cancelBackgroundWork() async {
        guard connection != nil else { return }
        _ = try? await performVoidInvocation(
            operation: "cancel-background",
            timeout: .seconds(5)
        ) { proxy, reply in proxy.cancelBackgroundWork(withReply: reply) }
    }

    public func cancelAll() async {
        guard connection != nil else { return }
        failAllPending(with: CancellationError())
        guard (try? await proxy()) != nil else { return }
        _ = try? await performVoidInvocation(
            operation: "cancel-all",
            timeout: .seconds(5)
        ) { proxy, reply in proxy.cancelAll(withReply: reply) }
    }

    public func unload(force: Bool = false) async {
        guard force || !retainsGemmaForIntentRouting else { return }
        guard connection != nil else { return }
        guard (try? await proxy()) != nil else {
            invalidate()
            return
        }
        _ = try? await performVoidInvocation(
            operation: "unload",
            timeout: .seconds(30)
        ) { proxy, reply in proxy.unload(withReply: reply) }
        invalidate()
    }

    public func invalidate() {
        invalidate(generation: nil)
    }

    private func invalidate(generation expectedGeneration: UUID?) {
        if let expectedGeneration,
           connectionGeneration != expectedGeneration {
            return
        }
        routingReleaseTask?.cancel()
        routingReleaseTask = nil
        let error = ContextWorkerTransportError.disconnected(
            "The context worker connection was closed.",
            generation: connectionGeneration
        )
        failAllPending(with: error)
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
        handshakeComplete = false
        handshakeTask = nil
        processIdentifier = nil
        onStateChange?(.idle)
    }

    private func request<Payload: Encodable>(
        operation: String,
        timeout: Duration,
        method: @escaping (
            ContextWorkerXPCProtocol,
            Data,
            @escaping (Data?) -> Void
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
                    let result: Data = try await performInvocation(
                        operation: operation,
                        timeout: timeout,
                        requestID: requestID
                    ) { proxy, reply in
                        method(proxy, encoded, reply)
                    }
                    try Task.checkCancellation()
                    consecutiveFailures = 0
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ContextWorkerTransportError {
                    if Task.isCancelled { throw CancellationError() }
                    switch error {
                    case .timeout:
                        await cancelRemoteRequest(requestID)
                        consecutiveFailures += 1
                        onStateChange?(.degraded)
                        throw error
                    case .disconnected(_, let generation):
                        lastError = error
                        if let generation {
                            invalidate(generation: generation)
                        }
                    }
                    if attempt == 0 {
                        Self.logger.notice(
                            "Retrying \(operation, privacy: .public) after a transport failure"
                        )
                        continue
                    }
                } catch {
                    throw error
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
            let generation = UUID()
            let connection = connectionFactory()
            connection.remoteObjectInterface = NSXPCInterface(
                with: ContextWorkerXPCProtocol.self
            )
            connection.interruptionHandler = Self.connectionEventHandler(
                client: self,
                generation: generation,
                degraded: true
            )
            connection.invalidationHandler = Self.connectionEventHandler(
                client: self,
                generation: generation,
                degraded: false
            )
            connection.resume()
            self.connection = connection
            connectionGeneration = generation
            Self.logger.debug(
                "Activated context worker connection \(generation.uuidString, privacy: .public)"
            )
        }
        guard let connection, let generation = connectionGeneration,
              let proxy = connection.remoteObjectProxyWithErrorHandler(
                Self.proxyErrorHandler(
                    client: self,
                    generation: generation
                )
              ) as? ContextWorkerXPCProtocol else {
            throw CurrentError.modelUnavailable(
                "Could not connect to the context worker."
            )
        }
        if !handshakeComplete {
            let task: Task<(Int, Int32), Error>
            if let handshakeTask {
                task = handshakeTask
            } else {
                let newTask = Task { @MainActor [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.performHandshake(
                        proxy: proxy,
                        generation: generation
                    )
                }
                handshakeTask = newTask
                task = newTask
            }
            let handshake: (Int, Int32)
            do {
                handshake = try await task.value
            } catch {
                if connectionGeneration == generation {
                    handshakeTask = nil
                }
                throw error
            }
            guard connectionGeneration == generation else {
                throw ContextWorkerTransportError.disconnected(
                    "The context worker connection changed during handshake.",
                    generation: generation
                )
            }
            handshakeTask = nil
            guard handshake.0 == ContextWorkerProtocolVersion.current else {
                invalidate(generation: generation)
                throw CurrentError.modelUnavailable(
                    "The context worker version does not match Current."
                )
            }
            processIdentifier = pid_t(handshake.1)
            handshakeComplete = true
        }
        return proxy
    }

    private func performHandshake(
        proxy: ContextWorkerXPCProtocol,
        generation: UUID
    ) async throws -> (Int, Int32) {
        let invocationID = UUID()
        defer { pendingInvocations.removeValue(forKey: invocationID) }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContextWorkerCompletionGate(continuation)
            pendingInvocations[invocationID] = ContextWorkerPendingInvocation(
                requestID: nil,
                fail: { error in gate.resume(with: .failure(error)) }
            )
            Self.scheduleTimeout(
                .seconds(5),
                operation: "handshake",
                gate: gate
            )
            proxy.handshake(
                withReply: Self.handshakeReplyHandler(
                    gate: gate,
                    client: self,
                    generation: generation
                )
            )
        }
    }

    private func performInvocation(
        operation: String,
        timeout: Duration,
        requestID: UUID?,
        invoke: (ContextWorkerXPCProtocol, @escaping (Data?) -> Void) -> Void
    ) async throws -> Data {
        let proxy = try await proxy()
        guard let generation = connectionGeneration else {
            throw ContextWorkerTransportError.disconnected(
                "The context worker connection is unavailable.",
                generation: nil
            )
        }
        let invocationID = UUID()
        let start = ContinuousClock.now
        defer { pendingInvocations.removeValue(forKey: invocationID) }
        let result: Data = try await withCheckedThrowingContinuation {
            continuation in
            let gate = ContextWorkerCompletionGate(continuation)
            pendingInvocations[invocationID] = ContextWorkerPendingInvocation(
                requestID: requestID,
                fail: { error in gate.resume(with: .failure(error)) }
            )
            Self.scheduleTimeout(timeout, operation: operation, gate: gate)
            invoke(
                proxy,
                Self.replyHandler(gate: gate, generation: generation)
            )
        }
        let elapsed = start.duration(to: .now)
        Self.logger.debug(
            "Completed \(operation, privacy: .public) in \(String(describing: elapsed), privacy: .public)"
        )
        return result
    }

    private func performVoidInvocation(
        operation: String,
        timeout: Duration,
        invoke: (ContextWorkerXPCProtocol, @escaping () -> Void) -> Void
    ) async throws {
        let proxy = try await proxy()
        let invocationID = UUID()
        defer { pendingInvocations.removeValue(forKey: invocationID) }
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContextWorkerCompletionGate<Void>(continuation)
            pendingInvocations[invocationID] = ContextWorkerPendingInvocation(
                requestID: nil,
                fail: { error in gate.resume(with: .failure(error)) }
            )
            Self.scheduleTimeout(timeout, operation: operation, gate: gate)
            invoke(proxy, Self.voidReplyHandler(gate: gate))
        }
    }

    private func cancelPendingRequest(_ requestID: UUID) {
        for invocation in pendingInvocations.values
        where invocation.requestID == requestID {
            invocation.fail(CancellationError())
        }
    }

    private func failAllPending(with error: Error) {
        let pending = pendingInvocations.values
        pendingInvocations.removeAll()
        for invocation in pending { invocation.fail(error) }
    }

    private func handleConnectionEvent(
        generation: UUID,
        degraded: Bool,
        message: String
    ) {
        guard connectionGeneration == generation else { return }
        let error = ContextWorkerTransportError.disconnected(
            message,
            generation: generation
        )
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
        handshakeComplete = false
        handshakeTask = nil
        processIdentifier = nil
        failAllPending(with: error)
        if degraded { onStateChange?(.degraded) }
        Self.logger.error(
            "Connection \(generation.uuidString, privacy: .public) failed: \(message, privacy: .public)"
        )
    }

    nonisolated private static func connectionEventHandler(
        client: ContextWorkerClient,
        generation: UUID,
        degraded: Bool
    ) -> @Sendable () -> Void {
        { [weak client] in
            Task { @MainActor [weak client] in
                client?.handleConnectionEvent(
                    generation: generation,
                    degraded: degraded,
                    message: degraded
                        ? "The context worker connection was interrupted."
                        : "The context worker connection was invalidated."
                )
            }
        }
    }

    nonisolated private static func proxyErrorHandler(
        client: ContextWorkerClient,
        generation: UUID
    ) -> @Sendable (Error) -> Void {
        { [weak client] error in
            let message = error.localizedDescription
            Task { @MainActor [weak client] in
                client?.handleConnectionEvent(
                    generation: generation,
                    degraded: true,
                    message: message
                )
            }
        }
    }

    nonisolated private static func handshakeReplyHandler(
        gate: ContextWorkerCompletionGate<(Int, Int32)>,
        client: ContextWorkerClient,
        generation: UUID
    ) -> @Sendable (Int, Int32) -> Void {
        { version, processIdentifier in
            gate.resume(with: .success((version, processIdentifier)))
        }
    }

    nonisolated private static func replyHandler(
        gate: ContextWorkerCompletionGate<Data>,
        generation: UUID
    ) -> @Sendable (Data?) -> Void {
        { data in
            do {
                guard let data else {
                    throw ContextWorkerTransportError.disconnected(
                        "The context worker returned no reply.",
                        generation: generation
                    )
                }
                switch try JSONDecoder().decode(
                    ContextWorkerReply.self,
                    from: data
                ) {
                case .success(let payload):
                    gate.resume(with: .success(payload))
                case .cancelled:
                    gate.resume(with: .failure(CancellationError()))
                case .failure(let message):
                    gate.resume(with: .failure(
                        CurrentError.modelUnavailable(message)
                    ))
                }
            } catch {
                gate.resume(with: .failure(error))
            }
        }
    }

    nonisolated private static func voidReplyHandler(
        gate: ContextWorkerCompletionGate<Void>
    ) -> @Sendable () -> Void {
        { gate.resume(with: .success(())) }
    }

    nonisolated private static func scheduleTimeout<Value: Sendable>(
        _ timeout: Duration,
        operation: String,
        gate: ContextWorkerCompletionGate<Value>
    ) {
        let task = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if gate.resume(with: .failure(
                ContextWorkerTransportError.timeout(operation)
            )) {
                logger.error("Timed out \(operation, privacy: .public)")
            }
        }
        gate.installTimeoutTask(task)
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
        _ request: PromptGenerationRequest
    ) async throws -> PromptGenerationDisposition {
        try await client.generatePrompt(snapshot: snapshot, request: request)
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
