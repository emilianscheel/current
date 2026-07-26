import CoreGraphics
import CurrentCore
import Foundation
import Vision

private final class ContextWorkerService: NSObject,
    ContextWorkerXPCProtocol, @unchecked Sendable {
    private final class ReplyBox: @unchecked Sendable {
        let callback: (Data?, String?) -> Void
        init(_ callback: @escaping (Data?, String?) -> Void) {
            self.callback = callback
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
        queue.name = "local.Current.ContextWorker.serial"
        queue.qualityOfService = .background
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private let gemma = GemmaWorkerInferenceEngine()
    private var currentTask: Task<Void, Never>?

    func handshake(withReply reply: @escaping (Int) -> Void) {
        reply(ContextWorkerProtocolVersion.current)
    }

    func recognizeText(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        enqueue(reply: ReplyBox(reply)) {
            let request = try JSONDecoder().decode(
                ContextWorkerOCRRequest.self,
                from: requestData
            )
            let image = try Self.image(from: request.image)
            defer { _ = image }
            let blocks = try Self.recognizeText(in: image)
            return try JSONEncoder().encode(blocks)
        }
    }

    func structureContext(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        enqueue(reply: ReplyBox(reply)) { [gemma] in
            let request = try JSONDecoder().decode(
                ContextWorkerStructureRequest.self,
                from: requestData
            )
            let snapshot = URL(fileURLWithPath: request.modelSnapshotPath)
            try await gemma.load(snapshot: snapshot)
            try Task.checkCancellation()
            let update = try await gemma.structure(
                currentState: request.currentState,
                observations: request.observations
            )
            return try JSONEncoder().encode(update)
        }
    }

    func cancelAll(withReply reply: @escaping () -> Void) {
        queue.cancelAllOperations()
        lock.withLock {
            currentTask?.cancel()
            currentTask = nil
        }
        reply()
    }

    func unload(withReply reply: @escaping () -> Void) {
        cancelAll {}
        let reply = VoidReplyBox(reply)
        let task = Task { [gemma] in
            await gemma.unload()
            reply.callback()
        }
        lock.withLock { currentTask = task }
    }

    private func enqueue(
        reply: ReplyBox,
        operation: @escaping @Sendable () async throws -> Data
    ) {
        queue.addOperation { [weak self] in
            guard let self else {
                reply.callback(nil, "The context worker operation was cancelled.")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task(priority: .background) {
                defer { semaphore.signal() }
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    reply.callback(result, nil)
                } catch {
                    reply.callback(nil, error.localizedDescription)
                }
            }
            lock.withLock { currentTask = task }
            semaphore.wait()
            lock.withLock { currentTask = nil }
        }
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
