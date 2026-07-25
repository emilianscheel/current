import AppKit
@preconcurrency import ApplicationServices
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
                y: displayFrame.y
                    + (1 - bounds.y - bounds.height) * displayFrame.height,
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

public enum PerceptualImageHasher {
    public static func hash(_ image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        var result: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    result |= bit
                }
                bit <<= 1
            }
        }
        return result
    }

    public static func isVisuallyEquivalent(
        _ lhs: UInt64,
        _ rhs: UInt64,
        threshold: Int = 4
    ) -> Bool {
        (lhs ^ rhs).nonzeroBitCount <= threshold
    }
}

@MainActor
public final class AccessibilityContextSource: AccessibilityContextProviding {
    private struct SnapshotResult {
        let observation: ContextObservation?
        let coverage: AccessibilityCoverage
    }

    private static let currentBundleIdentifier = "local.Current"

    private let repository: ContextRepository
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private var observers: [pid_t: AXObserver] = [:]
    private var debounceTasks: [pid_t: Task<Void, Never>] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var coverageByKey: [ContextCoverageKey: AccessibilityCoverage] = [:]

    public init(
        repository: ContextRepository,
        recoveryInterval: Duration = .seconds(30)
    ) {
        self.repository = repository
        _ = recoveryInterval
    }

    public func start() {
        guard workspaceTokens.isEmpty else { return }
        installObserversForRunningApplications()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = Self.application(from: notification)
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.isExcluded(application) else {
                        return
                    }
                    self.installObserver(for: application)
                    self.scheduleCapture(
                        processIdentifier: application.processIdentifier,
                        delay: .milliseconds(750)
                    )
                }
            }
        )
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = Self.application(from: notification)
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.isExcluded(application) else {
                        return
                    }
                    self.removeObserver(
                        processIdentifier: application.processIdentifier
                    )
                    await self.repository.applicationTerminated(
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
                guard let application = Self.application(from: notification)
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.isExcluded(application) else {
                        return
                    }
                    self.installObserver(for: application)
                    self.scheduleCapture(
                        processIdentifier: application.processIdentifier,
                        delay: .milliseconds(250)
                    )
                }
            }
        )
        Task { @MainActor [weak self] in
            _ = await self?.refreshVisibleCoverage()
        }
    }

    public func stop() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
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
        visibleApplications()
            .flatMap(Self.snapshotResults)
            .compactMap { result in
                result.coverage.isUseful ? result.observation : nil
            }
    }

    public func refreshVisibleCoverage() async -> [AccessibilityCoverage] {
        var refreshed: [AccessibilityCoverage] = []
        for application in visibleApplications() {
            installObserver(for: application)
            for result in Self.snapshotResults(application) {
                coverageByKey[result.coverage.key] = result.coverage
                refreshed.append(result.coverage)
                if result.coverage.isUseful,
                   let observation = result.observation {
                    await repository.accept(observation)
                }
            }
        }
        return refreshed
    }

    public func refreshCoverage(
        for target: ContextCaptureTarget
    ) async -> ContextCaptureDecision {
        guard let application = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ), !isExcluded(application) else {
            return .unavailable
        }
        installObserver(for: application)
        let results = Self.snapshotResults(application)
        let result = Self.matchingResult(results, target: target)
        guard let result else {
            return .screenshotFallback(
                ContextCoverageKey(
                    processIdentifier: target.processIdentifier,
                    windowIdentifier: target.windowIdentifier,
                    windowTitle: target.windowTitle
                )
            )
        }
        coverageByKey[result.coverage.key] = result.coverage
        guard result.coverage.isUseful,
              let observation = result.observation else {
            return .screenshotFallback(result.coverage.key)
        }
        await repository.accept(observation)
        return .accessibility(observation)
    }

    public func coverage(
        for target: ContextCaptureTarget
    ) async -> AccessibilityCoverage? {
        if let title = target.windowTitle {
            let exact = ContextCoverageKey(
                processIdentifier: target.processIdentifier,
                windowIdentifier: nil,
                windowTitle: title
            )
            if let value = coverageByKey[exact] {
                return value
            }
        }
        let matches = coverageByKey.values.filter {
            $0.key.processIdentifier == target.processIdentifier
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func installObserversForRunningApplications() {
        for application in NSWorkspace.shared.runningApplications
        where isVisible(application) && !isExcluded(application) {
            installObserver(for: application)
        }
    }

    private func installObserver(for application: NSRunningApplication) {
        guard !isExcluded(application) else { return }
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
                guard AXUIElementGetPid(element, &processIdentifier)
                        == .success else {
                    return
                }
                Task { @MainActor in
                    source.scheduleCapture(
                        processIdentifier: processIdentifier,
                        delay: .milliseconds(750)
                    )
                }
            },
            &observer
        )
        guard result == .success, let observer else { return }
        let applicationElement = AXUIElementCreateApplication(
            processIdentifier
        )
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
        debounceTasks.removeValue(forKey: processIdentifier)?.cancel()
        coverageByKey = coverageByKey.filter {
            $0.key.processIdentifier != processIdentifier
        }
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

    private func scheduleCapture(
        processIdentifier: pid_t,
        delay: Duration
    ) {
        guard processIdentifier != ownProcessIdentifier else { return }
        debounceTasks[processIdentifier]?.cancel()
        debounceTasks[processIdentifier] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.capture(processIdentifier: processIdentifier)
            self.debounceTasks.removeValue(forKey: processIdentifier)
        }
    }

    private func capture(processIdentifier: pid_t) async {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ), !isExcluded(application) else {
            return
        }
        for result in Self.snapshotResults(application) {
            coverageByKey[result.coverage.key] = result.coverage
            if result.coverage.isUseful,
               let observation = result.observation {
                await repository.accept(observation)
            }
        }
    }

    private func visibleApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            isVisible($0) && !isExcluded($0)
        }
    }

    private func isVisible(_ application: NSRunningApplication) -> Bool {
        !application.isTerminated
            && !application.isHidden
            && application.activationPolicy != .prohibited
    }

    private func isExcluded(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ownProcessIdentifier
            || application.bundleIdentifier == Self.currentBundleIdentifier
    }

    private nonisolated static func application(
        from notification: Notification
    ) -> NSRunningApplication? {
        notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication
    }

    private nonisolated static func snapshotResults(
        _ application: NSRunningApplication
    ) -> [SnapshotResult] {
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
        let attemptedAt = Date()
        return windows.enumerated().map { index, window in
            let title = stringAttribute(kAXTitleAttribute, from: window)
            let blocks = textBlocks(in: window)
            let key = ContextCoverageKey(
                processIdentifier: application.processIdentifier,
                windowTitle: title ?? "__untitled:\(index)"
            )
            let characterCount = blocks.reduce(into: 0) {
                $0 += ContextObservation.normalized($1.text).count
            }
            let coverage = AccessibilityCoverage(
                key: key,
                lastAttempt: attemptedAt,
                lastUsefulObservation: (
                    blocks.count >= 3 || characterCount >= 40
                ) ? attemptedAt : nil,
                blockCount: blocks.count,
                normalizedCharacterCount: characterCount
            )
            let observation = blocks.isEmpty ? nil : ContextObservation(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.localizedName ?? "Application",
                    windowTitle: title,
                    isFrontmost: application.isActive,
                    blocks: blocks
                )
            return SnapshotResult(
                observation: observation,
                coverage: coverage
            )
        }
    }

    private nonisolated static func matchingResult(
        _ results: [SnapshotResult],
        target: ContextCaptureTarget
    ) -> SnapshotResult? {
        if let title = target.windowTitle,
           !title.isEmpty {
            return results.first {
                $0.coverage.key.windowTitle == title
            }
        }
        return results.count == 1 ? results[0] : nil
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
    private struct CaptureRequest {
        let trigger: ContextCaptureTrigger
        let target: ContextCaptureTarget?
        let requestedAt: Date
    }

    private static let currentBundleIdentifier = "local.Current"
    private static let maximumCaptureLongEdge = 1_600
    private static let coalescingInterval: TimeInterval = 5
    private static let typingSettleDelay: Duration = .seconds(3)

    private let repository: ContextRepository
    private let ocr: any OCRProviding
    private let screenshotInterval: Duration
    private let accessibility: AccessibilityContextSource
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private var periodicTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var settleTasks: [String: Task<Void, Never>] = [:]
    private var pendingRequests: [String: CaptureRequest] = [:]
    private var recentCaptures: [String: Date] = [:]
    private var imageHashes: [String: UInt64] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var captureGeneration = UUID()
    private var isRunning = false
    private var isSleeping = false

    public init(
        repository: ContextRepository,
        ocr: any OCRProviding = VisionOCRService(),
        screenshotInterval: Duration = .seconds(30)
    ) {
        self.repository = repository
        self.ocr = ocr
        self.screenshotInterval = screenshotInterval
        accessibility = AccessibilityContextSource(
            repository: repository,
            recoveryInterval: screenshotInterval
        )
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            throw CurrentError.permissionMissing(.screenRecording)
        }
        isRunning = true
        isSleeping = false
        captureGeneration = UUID()
        accessibility.start()
        installNotifications()
        startPeriodicTimer()
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        isSleeping = false
        captureGeneration = UUID()
        periodicTask?.cancel()
        periodicTask = nil
        workerTask?.cancel()
        workerTask = nil
        for task in settleTasks.values {
            task.cancel()
        }
        settleTasks.removeAll()
        pendingRequests.removeAll()
        removeNotifications()
        accessibility.stop()
        await repository.stop()
    }

    public func scheduleCapture(
        trigger: ContextCaptureTrigger,
        target: ContextCaptureTarget? = nil
    ) async {
        guard isRunning, !isSleeping else { return }
        switch trigger {
        case .periodic:
            enqueue(
                CaptureRequest(
                    trigger: trigger,
                    target: nil,
                    requestedAt: Date()
                )
            )
        case .typingSettled, .textCommitted:
            guard let target, !isExcluded(target) else { return }
            let key = Self.captureIdentity(target)
            settleTasks[key]?.cancel()
            settleTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: Self.typingSettleDelay)
                guard !Task.isCancelled, let self else { return }
                self.settleTasks.removeValue(forKey: key)
                self.enqueue(
                    CaptureRequest(
                        trigger: trigger,
                        target: target,
                        requestedAt: Date()
                    )
                )
            }
        }
    }

    private func startPeriodicTimer() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.screenshotInterval)
                guard !Task.isCancelled else { return }
                await self.scheduleCapture(trigger: .periodic, target: nil)
            }
        }
    }

    private func enqueue(_ request: CaptureRequest) {
        guard isRunning, !isSleeping else { return }
        let key = Self.requestKey(request)
        if let target = request.target,
           let lastCapture = recentCaptures[Self.captureIdentity(target)],
           request.requestedAt.timeIntervalSince(lastCapture)
                < Self.coalescingInterval {
            return
        }
        pendingRequests[key] = request
        guard workerTask == nil else { return }
        let generation = captureGeneration
        workerTask = Task { [weak self] in
            await self?.drainPendingRequests(generation: generation)
        }
    }

    private func drainPendingRequests(generation: UUID) async {
        defer {
            if captureGeneration == generation {
                workerTask = nil
            }
        }
        while isRunning,
              !isSleeping,
              captureGeneration == generation,
              !pendingRequests.isEmpty {
            let request = nextPendingRequest()
            pendingRequests.removeValue(forKey: Self.requestKey(request))
            do {
                switch request.trigger {
                case .periodic:
                    try await captureAllDisplays()
                case .typingSettled, .textCommitted:
                    guard let target = request.target else { continue }
                    let decision = await accessibility.refreshCoverage(
                        for: target
                    )
                    if case .accessibility = decision {
                        continue
                    }
                    guard case .screenshotFallback = decision else {
                        continue
                    }
                    try await captureWindow(target)
                }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    private func nextPendingRequest() -> CaptureRequest {
        pendingRequests.values.max { lhs, rhs in
            let leftPriority = Self.priority(lhs.trigger)
            let rightPriority = Self.priority(rhs.trigger)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return lhs.requestedAt < rhs.requestedAt
        }!
    }

    private func captureAllDisplays() async throws {
        _ = await accessibility.refreshVisibleCoverage()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard isRunning, !isSleeping else { return }
        let windows = content.windows.filter { window in
            guard window.isOnScreen,
                  window.frame.width > 1,
                  window.frame.height > 1,
                  let application = window.owningApplication else {
                return false
            }
            return !isExcluded(application)
        }
        for window in windows {
            try Task.checkCancellation()
            guard isRunning, !isSleeping else { return }
            guard let application = window.owningApplication else {
                continue
            }
            let target = ContextCaptureTarget(
                processIdentifier: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                windowIdentifier: window.windowID,
                windowTitle: window.title
            )
            if await accessibility.coverage(for: target)?.isUseful == true {
                continue
            }
            try await captureResolvedWindow(
                window,
                content: content,
                target: target
            )
        }
    }

    private func captureWindow(_ target: ContextCaptureTarget) async throws {
        guard !isExcluded(target) else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard isRunning, !isSleeping,
              let window = Self.resolveWindow(
                  target,
                  from: content.windows,
                  excluding: isExcluded
              ),
              let application = window.owningApplication,
              !isExcluded(application) else {
            return
        }
        try await captureResolvedWindow(
            window,
            content: content,
            target: target
        )
    }

    private func captureResolvedWindow(
        _ window: SCWindow,
        content: SCShareableContent,
        target: ContextCaptureTarget
    ) async throws {
        let descriptor = Self.windowDescriptor(
            window,
            frontmostPID: NSWorkspace.shared.frontmostApplication?
                .processIdentifier
        )
        let configuration = Self.configuration(
            width: max(1, Int(window.frame.width)),
            height: max(1, Int(window.frame.height))
        )
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(
                desktopIndependentWindow: window
            ),
            configuration: configuration
        )
        try Task.checkCancellation()
        let capturedAt = Date()
        recentCaptures[Self.captureIdentity(descriptor)] = capturedAt
        recentCaptures[Self.captureIdentity(target)] = capturedAt
        let hashKey = "window:\(descriptor.processIdentifier):\(window.windowID)"
        guard shouldRunOCR(image: image, key: hashKey) else { return }
        let blocks = try await ocr.recognizeText(in: image)
        try Task.checkCancellation()
        guard isRunning, !isSleeping else { return }
        let displayIdentifier = content.displays.first {
            $0.frame.intersects(window.frame)
        }?.displayID ?? 0
        let observations = OCRWindowMapper.observations(
            blocks: blocks,
            displayIdentifier: displayIdentifier,
            displayFrame: descriptor.frame,
            windows: [descriptor],
            capturedAt: capturedAt
        )
        for observation in observations {
            await repository.accept(observation)
        }
    }

    private func shouldRunOCR(image: CGImage, key: String) -> Bool {
        guard let newHash = PerceptualImageHasher.hash(image) else {
            return true
        }
        defer { imageHashes[key] = newHash }
        guard let previousHash = imageHashes[key] else { return true }
        return !PerceptualImageHasher.isVisuallyEquivalent(
            previousHash,
            newHash
        )
    }

    private func installNotifications() {
        guard notificationTokens.isEmpty else { return }
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.scheduleCapture(
                        trigger: .periodic,
                        target: nil
                    )
                }
            }
        )
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.suspendForSleep()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumeAfterWake()
                }
            }
        )
    }

    private func removeNotifications() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func suspendForSleep() {
        guard isRunning else { return }
        isSleeping = true
        captureGeneration = UUID()
        periodicTask?.cancel()
        periodicTask = nil
        workerTask?.cancel()
        workerTask = nil
        for task in settleTasks.values {
            task.cancel()
        }
        settleTasks.removeAll()
        pendingRequests.removeAll()
    }

    private func resumeAfterWake() {
        guard isRunning, isSleeping else { return }
        isSleeping = false
        captureGeneration = UUID()
        startPeriodicTimer()
    }

    private func isExcluded(_ application: SCRunningApplication) -> Bool {
        application.processID == ownProcessIdentifier
            || application.bundleIdentifier == Self.currentBundleIdentifier
    }

    private func isExcluded(_ target: ContextCaptureTarget) -> Bool {
        target.processIdentifier == ownProcessIdentifier
            || target.bundleIdentifier == Self.currentBundleIdentifier
    }

    private static func resolveWindow(
        _ target: ContextCaptureTarget,
        from windows: [SCWindow],
        excluding isExcluded: (SCRunningApplication) -> Bool
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard window.isOnScreen,
                  window.frame.width > 1,
                  window.frame.height > 1,
                  let application = window.owningApplication else {
                return false
            }
            return application.processID == target.processIdentifier
                && !isExcluded(application)
        }
        if let windowIdentifier = target.windowIdentifier {
            return candidates.first { $0.windowID == windowIdentifier }
        }
        if let windowTitle = target.windowTitle
            ?? focusedWindowTitle(
                processIdentifier: target.processIdentifier
            ) {
            if let exactMatch = candidates.first(where: {
                $0.title == windowTitle
            }) {
                return exactMatch
            }
            return candidates.count == 1 ? candidates[0] : nil
        }
        return candidates.first
    }

    private static func focusedWindowTitle(
        processIdentifier: pid_t
    ) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue else {
            return nil
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowValue as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else {
            return nil
        }
        return titleValue as? String
    }

    private static func configuration(
        width: Int,
        height: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let longestEdge = max(width, height)
        let scale = longestEdge > maximumCaptureLongEdge
            ? Double(maximumCaptureLongEdge) / Double(longestEdge)
            : 1
        configuration.width = max(1, Int(Double(width) * scale))
        configuration.height = max(1, Int(Double(height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    private static func windowDescriptors(
        _ windows: [SCWindow],
        display: SCDisplay,
        frontmostPID: pid_t?,
        excluding isExcluded: (SCRunningApplication) -> Bool
    ) -> [WindowContextDescriptor] {
        windows.compactMap { window in
            guard window.isOnScreen,
                  window.frame.intersects(display.frame),
                  let application = window.owningApplication,
                  !isExcluded(application) else {
                return nil
            }
            return windowDescriptor(window, frontmostPID: frontmostPID)
        }
    }

    private static func windowDescriptor(
        _ window: SCWindow,
        frontmostPID: pid_t?
    ) -> WindowContextDescriptor {
        let application = window.owningApplication!
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

    private static func priority(_ trigger: ContextCaptureTrigger) -> Int {
        switch trigger {
        case .periodic: 0
        case .typingSettled: 1
        case .textCommitted: 2
        }
    }

    private static func requestKey(_ request: CaptureRequest) -> String {
        request.target.map(captureIdentity) ?? "periodic"
    }

    private static func captureIdentity(
        _ target: ContextCaptureTarget
    ) -> String {
        [
            String(target.processIdentifier),
            target.windowIdentifier.map(String.init) ?? "",
            target.windowTitle ?? "",
        ].joined(separator: ":")
    }

    private static func captureIdentity(
        _ descriptor: WindowContextDescriptor
    ) -> String {
        [
            String(descriptor.processIdentifier),
            String(descriptor.windowIdentifier),
            descriptor.title ?? "",
        ].joined(separator: ":")
    }
}
