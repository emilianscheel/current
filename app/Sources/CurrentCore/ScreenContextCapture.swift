import AppKit
@preconcurrency import ApplicationServices
import CoreImage
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

public actor VisionOCRService: OCRProviding {
    public init() {}

    public func recognizeText(
        in image: CGImage
    ) async throws -> [ContextTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
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

public struct WindowContextDescriptor: Sendable, Equatable {
    public let windowIdentifier: UInt32
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let title: String?
    public let frame: ContextBounds
    public let isFrontmost: Bool

    public init(
        windowIdentifier: UInt32,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        title: String?,
        frame: ContextBounds,
        isFrontmost: Bool
    ) {
        self.windowIdentifier = windowIdentifier
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.frame = frame
        self.isFrontmost = isFrontmost
    }
}

public enum OCRWindowMapper {
    public static func observations(
        blocks: [ContextTextBlock],
        displayIdentifier: UInt32,
        displayFrame: ContextBounds,
        windows: [WindowContextDescriptor],
        capturedAt: Date
    ) -> [ContextObservation] {
        var grouped: [UInt32: [ContextTextBlock]] = [:]
        for block in blocks {
            guard let bounds = block.bounds else { continue }
            let centerX = displayFrame.x
                + (bounds.x + bounds.width / 2) * displayFrame.width
            let centerY = displayFrame.y
                + (1 - bounds.y - bounds.height / 2) * displayFrame.height
            let candidates = windows.filter {
                contains(x: centerX, y: centerY, in: $0.frame)
            }
            let owner = candidates.first(where: \.isFrontmost)
                ?? candidates.min { area($0.frame) < area($1.frame) }
            guard let owner else { continue }
            let screenBounds = ContextBounds(
                x: displayFrame.x + bounds.x * displayFrame.width,
                y: displayFrame.y + (1 - bounds.y - bounds.height) * displayFrame.height,
                width: bounds.width * displayFrame.width,
                height: bounds.height * displayFrame.height
            )
            grouped[owner.windowIdentifier, default: []].append(
                ContextTextBlock(
                    id: block.id,
                    text: block.text,
                    source: block.source,
                    confidence: block.confidence,
                    bounds: screenBounds
                )
            )
        }
        return grouped.compactMap { windowIdentifier, groupedBlocks in
            guard let window = windows.first(where: {
                $0.windowIdentifier == windowIdentifier
            }) else {
                return nil
            }
            return ContextObservation(
                capturedAt: capturedAt,
                processIdentifier: window.processIdentifier,
                bundleIdentifier: window.bundleIdentifier,
                applicationName: window.applicationName,
                windowIdentifier: window.windowIdentifier,
                windowTitle: window.title,
                displayIdentifier: displayIdentifier,
                isFrontmost: window.isFrontmost,
                blocks: groupedBlocks
            )
        }
    }

    private static func contains(
        x: Double,
        y: Double,
        in bounds: ContextBounds
    ) -> Bool {
        x >= bounds.x
            && x <= bounds.x + bounds.width
            && y >= bounds.y
            && y <= bounds.y + bounds.height
    }

    private static func area(_ bounds: ContextBounds) -> Double {
        bounds.width * bounds.height
    }
}

@MainActor
public final class AccessibilityContextSource: AccessibilityContextProviding {
    private let repository: ContextRepository
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?

    public init(repository: ContextRepository) {
        self.repository = repository
    }

    public func start() {
        installObserversForRunningApplications()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.installObserver(for: application)
                    await self?.capture(processIdentifier: application.processIdentifier)
                }
            }
        )
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.removeObserver(processIdentifier: application.processIdentifier)
                    await self?.repository.applicationTerminated(
                        processIdentifier: application.processIdentifier
                    )
                }
            }
        )
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.capture(processIdentifier: application.processIdentifier)
                }
            }
        )
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let observations = await self.snapshotVisibleApplications()
                for observation in observations {
                    await self.repository.accept(observation)
                }
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observers.removeAll()
    }

    public func snapshotVisibleApplications() async -> [ContextObservation] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited
        }
        return applications.flatMap(Self.snapshot)
    }

    private func installObserversForRunningApplications() {
        for application in NSWorkspace.shared.runningApplications
        where !application.isTerminated && application.activationPolicy != .prohibited {
            installObserver(for: application)
        }
    }

    private func installObserver(for application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        guard observers[processIdentifier] == nil else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(
            processIdentifier,
            { _, element, _, pointer in
                guard let pointer else { return }
                let source = Unmanaged<AccessibilityContextSource>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                var processIdentifier: pid_t = 0
                guard AXUIElementGetPid(element, &processIdentifier) == .success else {
                    return
                }
                Task { @MainActor in
                    await source.capture(processIdentifier: processIdentifier)
                }
            },
            &observer
        )
        guard result == .success, let observer else { return }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification,
            kAXTitleChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(
                observer,
                applicationElement,
                notification as CFString,
                pointer
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observers[processIdentifier] = observer
    }

    private func removeObserver(processIdentifier: pid_t) {
        guard let observer = observers.removeValue(
            forKey: processIdentifier
        ) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func capture(processIdentifier: pid_t) async {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ) else {
            return
        }
        for observation in Self.snapshot(application) {
            await repository.accept(observation)
        }
    }

    private nonisolated static func snapshot(
        _ application: NSRunningApplication
    ) -> [ContextObservation] {
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        let windows = elementsAttribute(
            kAXWindowsAttribute,
            from: appElement
        )
        return windows.compactMap { window in
            let title = stringAttribute(kAXTitleAttribute, from: window)
            let blocks = textBlocks(in: window)
            guard !blocks.isEmpty else { return nil }
            return ContextObservation(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.localizedName ?? "Application",
                windowTitle: title,
                isFrontmost: application.isActive,
                blocks: blocks
            )
        }
    }

    private nonisolated static func textBlocks(
        in root: AXUIElement
    ) -> [ContextTextBlock] {
        var queue = [root]
        var index = 0
        var visited = 0
        var seen: Set<String> = []
        var blocks: [ContextTextBlock] = []
        while index < queue.count, visited < 500, blocks.count < 160 {
            let element = queue[index]
            index += 1
            visited += 1
            for attribute in [
                kAXTitleAttribute,
                kAXValueAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
            ] {
                guard let text = stringAttribute(attribute, from: element)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      text.count <= 8_000 else {
                    continue
                }
                let normalized = ContextObservation.normalized(text)
                guard !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                blocks.append(
                    ContextTextBlock(
                        text: text,
                        source: .accessibility
                    )
                )
            }
            queue.append(
                contentsOf: elementsAttribute(
                    kAXChildrenAttribute,
                    from: element
                )
            )
        }
        return blocks
    }

    private nonisolated static func stringAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func elementsAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }
}

@MainActor
public final class ScreenContextCoordinator: ScreenContextProviding {
    private let repository: ContextRepository
    private let ocr: any OCRProviding
    private let framesPerSecond: Double
    private let accessibility: AccessibilityContextSource
    private var streams: [SCStream] = []
    private var outputs: [DisplayStreamOutput] = []
    private var refreshTask: Task<Void, Never>?
    private var screenChangeToken: NSObjectProtocol?
    private var isRunning = false

    public init(
        repository: ContextRepository,
        ocr: any OCRProviding = VisionOCRService(),
        framesPerSecond: Double = 1
    ) {
        self.repository = repository
        self.ocr = ocr
        self.framesPerSecond = max(0.2, framesPerSecond)
        accessibility = AccessibilityContextSource(repository: repository)
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            throw CurrentError.permissionMissing(.screenRecording)
        }
        isRunning = true
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let frontmostPID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier
            for display in content.displays {
                let descriptors = Self.windowDescriptors(
                    content.windows,
                    display: display,
                    frontmostPID: frontmostPID
                )
                let output = DisplayStreamOutput(
                    repository: repository,
                    ocr: ocr,
                    display: display,
                    windows: descriptors
                )
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, display.width)
                configuration.height = max(1, display.height)
                configuration.minimumFrameInterval = CMTime(
                    seconds: 1 / framesPerSecond,
                    preferredTimescale: 600
                )
                configuration.queueDepth = 1
                configuration.showsCursor = false
                configuration.capturesAudio = false
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )
                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: output
                )
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: output.queue
                )
                try await stream.startCapture()
                outputs.append(output)
                streams.append(stream)
            }
            accessibility.start()
            startWindowRefresh()
            screenChangeToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.restart()
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        accessibility.stop()
        if let screenChangeToken {
            NotificationCenter.default.removeObserver(screenChangeToken)
            self.screenChangeToken = nil
        }
        for stream in streams {
            try? await stream.stopCapture()
        }
        streams.removeAll()
        outputs.removeAll()
        await repository.stop()
    }

    private func restart() async {
        await stop()
        try? await start()
    }

    private func startWindowRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard let content = try? await SCShareableContent
                    .excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    ) else {
                    continue
                }
                let frontmostPID = NSWorkspace.shared.frontmostApplication?
                    .processIdentifier
                for output in self.outputs {
                    let display = output.display
                    output.update(
                        windows: Self.windowDescriptors(
                            content.windows,
                            display: display,
                            frontmostPID: frontmostPID
                        )
                    )
                }
            }
        }
    }

    private static func windowDescriptors(
        _ windows: [SCWindow],
        display: SCDisplay,
        frontmostPID: pid_t?
    ) -> [WindowContextDescriptor] {
        windows.compactMap { window in
            guard window.isOnScreen,
                  window.frame.intersects(display.frame),
                  let application = window.owningApplication else {
                return nil
            }
            return WindowContextDescriptor(
                windowIdentifier: window.windowID,
                processIdentifier: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                title: window.title,
                frame: ContextBounds(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y,
                    width: window.frame.width,
                    height: window.frame.height
                ),
                isFrontmost: application.processID == frontmostPID
            )
        }
    }
}

private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    let queue: DispatchQueue
    let display: SCDisplay
    private let repository: ContextRepository
    private let ocr: any OCRProviding
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var windows: [WindowContextDescriptor]
    private var processing = false

    init(
        repository: ContextRepository,
        ocr: any OCRProviding,
        display: SCDisplay,
        windows: [WindowContextDescriptor]
    ) {
        self.repository = repository
        self.ocr = ocr
        self.display = display
        self.windows = windows
        queue = DispatchQueue(
            label: "local.Current.screen-context.\(display.displayID)",
            qos: .utility
        )
    }

    func update(windows: [WindowContextDescriptor]) {
        lock.withLock { self.windows = windows }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              lock.withLock({
                  guard !processing else { return false }
                  processing = true
                  return true
              }),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let rawStatus = attachment[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            lock.withLock { processing = false }
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(
            image,
            from: image.extent
        ) else {
            lock.withLock { processing = false }
            return
        }
        let windows = lock.withLock { self.windows }
        let displayFrame = ContextBounds(
            x: display.frame.origin.x,
            y: display.frame.origin.y,
            width: display.frame.width,
            height: display.frame.height
        )
        Task { [ocr, repository, displayID = display.displayID] in
            defer { self.lock.withLock { self.processing = false } }
            guard let blocks = try? await ocr.recognizeText(in: cgImage) else {
                return
            }
            let observations = OCRWindowMapper.observations(
                blocks: blocks,
                displayIdentifier: displayID,
                displayFrame: displayFrame,
                windows: windows,
                capturedAt: Date()
            )
            for observation in observations {
                await repository.accept(observation)
            }
        }
    }
}
