import CoreGraphics
import CurrentCore
import Foundation
import Vision

private final class ContextWorkerService: NSObject,
    ContextWorkerXPCProtocol, @unchecked Sendable {
    private final class ReplyBox: @unchecked Sendable {
        let callback: (Data?) -> Void
        private let lock = NSLock()
        private var didReply = false
        init(_ callback: @escaping (Data?) -> Void) {
            self.callback = callback
        }

        func send(_ result: ContextWorkerReply) {
            let shouldSend = lock.withLock {
                guard !didReply else { return false }
                didReply = true
                return true
            }
            guard shouldSend else { return }
            callback(try? JSONEncoder().encode(result))
        }
    }

    private final class VoidReplyBox: @unchecked Sendable {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) {
            self.callback = callback
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.emilianscheel.current.ContextWorker.serial"
        queue.qualityOfService = .background
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private let gemma = GemmaWorkerInferenceEngine()
    private struct PendingJob {
        let priority: ContextWorkerRequestPriority
        let operation: Operation
        let reply: ReplyBox
    }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var jobs: [UUID: PendingJob] = [:]

    func handshake(withReply reply: @escaping (Int, Int32) -> Void) {
        reply(
            ContextWorkerProtocolVersion.current,
            ProcessInfo.processInfo.processIdentifier
        )
    }

    func recognizeText(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(
                ContextWorkerOCRRequest.self,
                from: requestData
            )
            enqueue(
                requestID: request.requestID,
                priority: request.priority,
                reply: ReplyBox(reply)
            ) {
            let image = try Self.image(from: request.image)
            defer { _ = image }
            let blocks = try Self.recognizeText(in: image)
            return try JSONEncoder().encode(blocks)
            }
        } catch {
            ReplyBox(reply).send(.failure(error.localizedDescription))
        }
    }

    func structureContext(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(
                ContextWorkerStructureRequest.self,
                from: requestData
            )
            enqueue(
                requestID: request.requestID,
                priority: request.priority,
                reply: ReplyBox(reply)
            ) { [gemma] in
            let snapshot = URL(fileURLWithPath: request.modelSnapshotPath)
            try await gemma.load(snapshot: snapshot)
            try Task.checkCancellation()
            let update = try await gemma.structure(
                currentState: request.currentState,
                observations: request.observations
            )
            return try JSONEncoder().encode(update)
            }
        } catch {
            ReplyBox(reply).send(.failure(error.localizedDescription))
        }
    }

    func generatePrompt(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(
                ContextWorkerPromptRequest.self,
                from: requestData
            )
            enqueue(
                requestID: request.requestID,
                priority: request.priority,
                reply: ReplyBox(reply)
            ) { [gemma] in
                let snapshot = URL(fileURLWithPath: request.modelSnapshotPath)
                try await gemma.load(snapshot: snapshot)
                try Task.checkCancellation()
                let response = try await gemma.generatePrompt(
                    request: request.generationRequest
                )
                return try JSONEncoder().encode(response)
            }
        } catch {
            ReplyBox(reply).send(.failure(error.localizedDescription))
        }
    }

    func prepareIntentModel(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(
                ContextWorkerModelPreparationRequest.self,
                from: requestData
            )
            enqueue(
                requestID: request.requestID,
                priority: request.priority,
                reply: ReplyBox(reply)
            ) { [gemma] in
                try await gemma.load(
                    snapshot: URL(fileURLWithPath: request.modelSnapshotPath)
                )
                return try JSONEncoder().encode(true)
            }
        } catch {
            ReplyBox(reply).send(.failure(error.localizedDescription))
        }
    }

    func classifyIntent(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(
                ContextWorkerIntentRequest.self,
                from: requestData
            )
            enqueue(
                requestID: request.requestID,
                priority: request.priority,
                reply: ReplyBox(reply)
            ) { [gemma] in
                try await gemma.load(
                    snapshot: URL(fileURLWithPath: request.modelSnapshotPath)
                )
                try Task.checkCancellation()
                let decision = try await gemma.classifyIntent(
                    request: request.routingRequest
                )
                return try JSONEncoder().encode(decision)
            }
        } catch {
            ReplyBox(reply).send(.failure(error.localizedDescription))
        }
    }

    func cancelRequest(
        _ requestData: Data,
        withReply reply: @escaping () -> Void
    ) {
        if let request = try? JSONDecoder().decode(
            ContextWorkerCancellationRequest.self,
            from: requestData
        ) {
            cancelJobs { $0 == request.requestID }
        }
        reply()
    }

    func cancelBackgroundWork(withReply reply: @escaping () -> Void) {
        cancelBackgroundJobs()
        reply()
    }

    func cancelAll(withReply reply: @escaping () -> Void) {
        cancelJobs { _ in true }
        reply()
    }

    func unload(withReply reply: @escaping () -> Void) {
        cancelAll {}
        let reply = VoidReplyBox(reply)
        let taskID = UUID()
        let task = Task { [weak self, gemma] in
            await gemma.unload()
            reply.callback()
            _ = self?.lock.withLock {
                self?.tasks.removeValue(forKey: taskID)
            }
        }
        lock.withLock { tasks[taskID] = task }
    }

    private func enqueue(
        requestID: UUID,
        priority: ContextWorkerRequestPriority,
        reply: ReplyBox,
        operation: @escaping @Sendable () async throws -> Data
    ) {
        if priority != .background {
            cancelBackgroundJobs()
        }
        let queued = BlockOperation { [weak self] in
            guard let self else {
                reply.send(.cancelled)
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task(
                priority: priority == .background
                    ? .background : .userInitiated
            ) {
                defer { semaphore.signal() }
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    reply.send(.success(result))
                } catch is CancellationError {
                    reply.send(.cancelled)
                } catch {
                    reply.send(.failure(error.localizedDescription))
                }
            }
            lock.withLock { tasks[requestID] = task }
            semaphore.wait()
            lock.withLock {
                tasks.removeValue(forKey: requestID)
                jobs.removeValue(forKey: requestID)
            }
        }
        switch priority {
        case .background:
            queued.queuePriority = .low
            queued.qualityOfService = .background
        case .interactive:
            queued.queuePriority = .high
            queued.qualityOfService = .userInitiated
        case .voiceRouting:
            queued.queuePriority = .veryHigh
            queued.qualityOfService = .userInitiated
        }
        lock.withLock {
            jobs[requestID] = PendingJob(
                priority: priority,
                operation: queued,
                reply: reply
            )
        }
        queue.addOperation(queued)
    }

    private func cancelJobs(where shouldCancel: (UUID) -> Bool) {
        let cancelled: [(Operation, ReplyBox, Task<Void, Never>?)] = lock.withLock {
            let ids = jobs.keys.filter(shouldCancel)
            let values = ids.compactMap { id -> (Operation, ReplyBox, Task<Void, Never>?)? in
                guard let job = jobs.removeValue(forKey: id) else { return nil }
                return (job.operation, job.reply, tasks.removeValue(forKey: id))
            }
            return values
        }
        for (operation, reply, task) in cancelled {
            operation.cancel()
            task?.cancel()
            reply.send(.cancelled)
        }
    }

    private func cancelBackgroundJobs() {
        let identifiers = lock.withLock {
            jobs.compactMap { key, value in
                value.priority == .background ? key : nil
            }
        }
        let selected = Set(identifiers)
        cancelJobs { selected.contains($0) }
    }

    private static func image(
        from payload: ContextWorkerImagePayload
    ) throws -> CGImage {
        _ = try ContextWorkerImagePayload(
            bgraData: payload.bgraData,
            width: payload.width,
            height: payload.height,
            bytesPerRow: payload.bytesPerRow
        )
        guard let provider = CGDataProvider(
            data: payload.bgraData as CFData
        ), let image = CGImage(
            width: payload.width,
            height: payload.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: payload.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CurrentError.modelUnavailable(
                "The context worker could not decode the image payload."
            )
        }
        return image
    }

    private static func recognizeText(
        in image: CGImage
    ) throws -> [ContextTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.25 else {
                return nil
            }
            let box = observation.boundingBox
            return ContextTextBlock(
                text: candidate.string,
                source: .visionOCR,
                confidence: candidate.confidence,
                bounds: ContextBounds(
                    x: box.origin.x,
                    y: box.origin.y,
                    width: box.width,
                    height: box.height
                )
            )
        }
    }
}

private final class ContextWorkerListenerDelegate: NSObject,
    NSXPCListenerDelegate {
    private let service = ContextWorkerService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: ContextWorkerXPCProtocol.self
        )
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let listener = NSXPCListener.service()
private let delegate = ContextWorkerListenerDelegate()
listener.delegate = delegate
listener.resume()
