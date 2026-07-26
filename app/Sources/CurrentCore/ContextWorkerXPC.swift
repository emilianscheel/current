import CoreGraphics
import Foundation

public enum ContextWorkerProtocolVersion {
    public static let current = 1
    public static let serviceName = "local.Current.ContextWorker"
}

@objc public protocol ContextWorkerXPCProtocol {
    func handshake(withReply reply: @escaping (Int) -> Void)
    func recognizeText(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func structureContext(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func cancelAll(withReply reply: @escaping () -> Void)
    func unload(withReply reply: @escaping () -> Void)
}

public struct ContextWorkerOCRRequest: Codable, Sendable {
    public let requestID: UUID
    public let image: ContextWorkerImagePayload

    public init(requestID: UUID = UUID(), image: ContextWorkerImagePayload) {
        self.requestID = requestID
        self.image = image
    }
}

public struct ContextWorkerStructureRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelSnapshotPath: String
    public let currentState: String
    public let observations: [ContextObservation]

    public init(
        requestID: UUID = UUID(),
        modelSnapshotPath: String,
        currentState: String,
        observations: [ContextObservation]
    ) {
        self.requestID = requestID
        self.modelSnapshotPath = modelSnapshotPath
        self.currentState = currentState
        self.observations = observations
    }
}

@MainActor
public final class ContextWorkerClient: @unchecked Sendable {
    public var onStateChange: (@MainActor (ContextBackgroundState) -> Void)?

    private var connection: NSXPCConnection?
    private var handshakeComplete = false
    private var consecutiveFailures = 0

    public init() {}

    public func recognizeText(
        image: ContextWorkerImagePayload
    ) async throws -> [ContextTextBlock] {
        let payload = ContextWorkerOCRRequest(image: image)
        let response = try await request(
            method: { proxy, data, reply in
                proxy.recognizeText(data, withReply: reply)
            },
            payload: payload
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
            payload: payload
        )
        return try JSONDecoder().decode(
            ContextDocumentUpdate.self,
            from: response
        )
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

    public func unload() async {
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
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        handshakeComplete = false
        onStateChange?(.idle)
    }

    private func request<Payload: Encodable>(
        method: @escaping (
            ContextWorkerXPCProtocol,
            Data,
            @escaping (Data?, String?) -> Void
        ) -> Void,
        payload: Payload
    ) async throws -> Data {
        let encoded = try JSONEncoder().encode(payload)
        var lastError: Error?
        for attempt in 0..<2 {
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
                consecutiveFailures = 0
                return result
            } catch {
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
                    self?.onStateChange?(.degraded)
                }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.connection = nil
                    self?.handshakeComplete = false
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
                      self?.onStateChange?(.degraded)
                  }
              }) as? ContextWorkerXPCProtocol else {
            throw CurrentError.modelUnavailable(
                "Could not connect to the context worker."
            )
        }
        if !handshakeComplete {
            let version = await withCheckedContinuation { continuation in
                proxy.handshake { continuation.resume(returning: $0) }
            }
            guard version == ContextWorkerProtocolVersion.current else {
                invalidate()
                throw CurrentError.modelUnavailable(
                    "The context worker version does not match Current."
                )
            }
            handshakeComplete = true
        }
        return proxy
    }
}

public actor XPCVisionOCRProvider: OCRProviding {
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
