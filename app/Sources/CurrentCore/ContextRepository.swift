import AppKit
import Foundation

public actor ContextRepository {
    private struct SessionKey: Hashable {
        let processIdentifier: pid_t
        let dayIdentifier: String
    }

    private let store: ContextStore
    private let structurer: any ContextStructuringProviding
    private let excludedBundleIdentifiers: Set<String>
    private let excludedProcessIdentifiers: Set<pid_t>
    private var calendar: Calendar
    private var liveContexts: [SessionKey: LiveAppContext] = [:]
    private var processingSessions: Set<SessionKey> = []
    private var processingTasks: [SessionKey: Task<Void, Never>] = [:]
    private var firstPendingAt: [SessionKey: Date] = [:]
    private var failureCounts: [SessionKey: Int] = [:]
    private var unprocessedFailureBatches: [SessionKey: Set<String>] = [:]
    private var suppressedSessions: Set<SessionKey> = []
    private var closingSessions: Set<AppSessionID> = []
    private var isMigratingDocuments = false

    public init(
        store: ContextStore,
        structurer: any ContextStructuringProviding,
        calendar: Calendar = .autoupdatingCurrent,
        excludedBundleIdentifiers: Set<String> =
            ContextApplicationExclusions.bundleIdentifiers,
        excludedProcessIdentifiers: Set<pid_t> = [
            ProcessInfo.processInfo.processIdentifier,
        ]
    ) {
        self.store = store
        self.structurer = structurer
        self.calendar = calendar
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludedProcessIdentifiers = excludedProcessIdentifiers
    }

    @discardableResult
    public func accept(_ observation: ContextObservation) async -> Bool {
        await accept(observation, scheduleProcessing: true)
    }

    @discardableResult
    public func acceptAndProcess(
        _ observation: ContextObservation
    ) async -> Bool {
        let accepted = await accept(
            observation,
            scheduleProcessing: false
        )
        guard accepted else { return false }
        let key = SessionKey(
            processIdentifier: observation.processIdentifier,
            dayIdentifier: Self.dayIdentifier(
                for: observation.capturedAt,
                calendar: calendar
            )
        )
        processingTasks.removeValue(forKey: key)?.cancel()
        await processPending(for: key)
        return true
    }

    private func accept(
        _ observation: ContextObservation,
        scheduleProcessing shouldSchedule: Bool
    ) async -> Bool {
        guard !observation.blocks.isEmpty,
              !isExcluded(
                  processIdentifier: observation.processIdentifier,
                  bundleIdentifier: observation.bundleIdentifier
              ) else {
            return false
        }
        let dayIdentifier = Self.dayIdentifier(
            for: observation.capturedAt,
            calendar: calendar
        )
        await rollPreviousDayIfNeeded(
            processIdentifier: observation.processIdentifier,
            dayIdentifier: dayIdentifier,
            at: observation.capturedAt
        )
        let key = SessionKey(
            processIdentifier: observation.processIdentifier,
            dayIdentifier: dayIdentifier
        )
        guard !suppressedSessions.contains(key) else { return false }
        var context: LiveAppContext
        if let existing = liveContexts[key] {
            context = existing
            closingSessions.remove(existing.session.sessionID)
        } else {
            let session = await makeSession(
                for: observation,
                dayIdentifier: dayIdentifier
            )
            context = LiveAppContext(session: session)
        }
        let windowKey = Self.windowKey(for: observation)
        let merged = Self.merged(
            previous: context.observationsByWindow[windowKey],
            incoming: observation
        )
        guard context.observationsByWindow[windowKey]?.normalizedText
            != merged.normalizedText else {
            return false
        }
        context.observationsByWindow[windowKey] = merged
        context.pendingObservations.append(merged)
        context.session.sources.formUnion(merged.blocks.map(\.source))
        liveContexts[key] = context
        if shouldSchedule {
            scheduleProcessing(for: key)
        }
        return true
    }

    public func snapshot() -> [LiveAppContext] {
        liveContexts.values.filter {
            !isExcluded(
                processIdentifier: $0.session.processIdentifier,
                bundleIdentifier: $0.session.bundleIdentifier
            )
        }.sorted {
            ($0.latestObservation?.capturedAt ?? .distantPast)
                > ($1.latestObservation?.capturedAt ?? .distantPast)
        }
    }

    private func isExcluded(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> Bool {
        excludedProcessIdentifiers.contains(processIdentifier)
            || bundleIdentifier.map(excludedBundleIdentifiers.contains) == true
    }

    public func promptContext(
        instruction: String,
        focusedContext: DictationContext
    ) async -> PromptContextEnvelope {
        let live = snapshot()
        let target = live.first {
            guard let bundle = focusedContext.bundleIdentifier else {
                return $0.latestObservation?.isFrontmost == true
            }
            return $0.session.bundleIdentifier == bundle
        }
        let targetDocument: ContextDocument? = if let target {
            await store.appSessionDocument(sessionID: target.session.sessionID)
        } else {
            nil
        }
        let targetContext = [
            targetDocument?.markdown,
            target?.visibleText,
            target?.pendingObservations.map(Self.render).joined(separator: "\n\n"),
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\nLatest live observations:\n")

        var otherContexts: [String] = []
        for context in live where context.session.sessionID != target?.session.sessionID {
            let document = await store.appSessionDocument(
                sessionID: context.session.sessionID
            )
            let currentState = document.map {
                ContextStore.section(named: "Current state", in: $0.markdown)
            }
            otherContexts.append(
                [
                    "\(context.session.applicationName) (\(context.session.bundleIdentifier ?? "unknown bundle"))",
                    currentState,
                    context.visibleText,
                ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
        return PromptContextEnvelope(
            instruction: instruction,
            focusedContext: focusedContext,
            targetApplicationContext: targetContext,
            otherVisibleApplicationContexts: otherContexts
        )
    }

    public func applicationTerminated(
        processIdentifier: pid_t,
        at date: Date = Date()
    ) async {
        let keys = liveContexts.keys.filter {
            $0.processIdentifier == processIdentifier
        }
        for key in keys {
            if let context = liveContexts[key] {
                closingSessions.insert(context.session.sessionID)
            }
            await flush(key: key, unprocessedOnFailure: true)
            liveContexts.removeValue(forKey: key)
            failureCounts.removeValue(forKey: key)
            unprocessedFailureBatches.removeValue(forKey: key)
        }
        suppressedSessions = suppressedSessions.filter {
            $0.processIdentifier != processIdentifier
        }
        try? await store.closeAppSessions(
            processIdentifier: processIdentifier,
            at: date
        )
    }

    public func stop(at date: Date = Date()) async {
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        for key in Array(liveContexts.keys) {
            if let context = liveContexts[key] {
                closingSessions.insert(context.session.sessionID)
            }
            await flush(key: key, unprocessedOnFailure: true)
        }
        try? await store.closeAppSessions(at: date)
        processingSessions.removeAll()
    }

    public func discardSession(documentID: String) {
        guard documentID.hasPrefix("app:") else { return }
        let rawID = String(documentID.dropFirst(4))
        guard let key = liveContexts.first(where: {
            $0.value.session.sessionID.rawValue == rawID
        })?.key else {
            return
        }
        suppressedSessions.insert(key)
        processingTasks.removeValue(forKey: key)?.cancel()
        processingSessions.remove(key)
        firstPendingAt.removeValue(forKey: key)
        failureCounts.removeValue(forKey: key)
        unprocessedFailureBatches.removeValue(forKey: key)
        liveContexts.removeValue(forKey: key)
    }

    public func migrateLegacyDocuments() async {
        guard !isMigratingDocuments else { return }
        isMigratingDocuments = true
        defer { isMigratingDocuments = false }
        let documents = await store.appSessionDocumentsRequiringMigration()
        for document in documents {
            guard case .appSession(let metadata) = document.kind,
                  !isExcluded(
                      processIdentifier: metadata.processIdentifier,
                      bundleIdentifier: metadata.bundleIdentifier
                  ) else {
                continue
            }
            do {
                let currentState = ContextStore.section(
                    named: "Current state",
                    in: document.markdown
                )
                let structuredCurrent = try await structureLegacyText(
                    currentState,
                    metadata: metadata,
                    preferActivity: false
                )
                let activity = ContextStore.section(
                    named: "Activity",
                    in: document.markdown
                )
                var migratedEntries: [String] = []
                for entry in Self.activityEntries(activity) {
                    let structured = try await structureLegacyText(
                        entry.body,
                        metadata: metadata,
                        preferActivity: true
                    )
                    migratedEntries.append(
                        "\(entry.heading)\n\n\(structured)"
                    )
                }
                try await store.migrateAppSessionDocument(
                    documentID: document.id,
                    currentState: structuredCurrent,
                    activity: migratedEntries.joined(separator: "\n\n")
                )
            } catch {
                continue
            }
        }
    }

    private func scheduleProcessing(for key: SessionKey) {
        guard !processingSessions.contains(key) else { return }
        let now = Date()
        let first = firstPendingAt[key] ?? now
        firstPendingAt[key] = first
        let elapsed = now.timeIntervalSince(first)
        let delay = max(0, min(5, 30 - elapsed))
        processingTasks.removeValue(forKey: key)?.cancel()
        processingTasks[key] = Task { [weak self] in
            try? await Task.sleep(
                for: .milliseconds(Int64(delay * 1_000))
            )
            guard !Task.isCancelled else { return }
            await self?.processPending(for: key)
        }
    }

    private func structureLegacyText(
        _ text: String,
        metadata: AppSessionMetadata,
        preferActivity: Bool
    ) async throws -> String {
        guard !text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return ""
        }
        var outputLines: [String] = []
        for chunk in Self.textChunks(text, maximumCharacters: 10_000) {
            let observation = ContextObservation(
                capturedAt: metadata.startedAt,
                processIdentifier: metadata.processIdentifier,
                bundleIdentifier: metadata.bundleIdentifier,
                applicationName: metadata.applicationName,
                blocks: [
                    ContextTextBlock(
                        text: chunk,
                        source: .accessibility
                    ),
                ]
            )
            let update = try await structurer.updateContextDocument(
                currentState: "",
                observations: [observation]
            )
            if preferActivity,
               let activity = update.activityEntryMarkdown,
               !activity.isEmpty {
                outputLines.append(
                    contentsOf: activity.components(separatedBy: .newlines)
                )
            } else {
                outputLines.append(
                    contentsOf: update.currentStateMarkdown.components(
                        separatedBy: .newlines
                    )
                )
            }
        }
        return ContextBulletNormalizer.bullets(
            outputLines,
            maximumCount: preferActivity ? 12 : 24
        ).joined(separator: "\n")
    }

    private static func textChunks(
        _ text: String,
        maximumCharacters: Int
    ) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            chunks.append(String(text[start ..< end]))
            start = end
        }
        return chunks
    }

    private static func activityEntries(
        _ activity: String
    ) -> [(heading: String, body: String)] {
        var entries: [(String, String)] = []
        var heading: String?
        var body: [String] = []
        func appendCurrent() {
            guard let heading else { return }
            entries.append(
                (
                    heading,
                    body.joined(separator: "\n")
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                )
            )
        }
        for line in activity.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") {
                appendCurrent()
                heading = line
                body = []
            } else if heading != nil {
                body.append(line)
            }
        }
        appendCurrent()
        return entries
    }

    private func processPending(for key: SessionKey) async {
        processingTasks.removeValue(forKey: key)
        guard !suppressedSessions.contains(key) else { return }
        processingSessions.insert(key)
        defer {
            processingSessions.remove(key)
            if liveContexts[key]?.pendingObservations.isEmpty == false {
                scheduleProcessing(for: key)
            }
        }
        guard var context = liveContexts[key],
              !context.pendingObservations.isEmpty else {
            return
        }
        let pending = context.pendingObservations
        context.pendingObservations = []
        liveContexts[key] = context
        firstPendingAt.removeValue(forKey: key)
        do {
            let document = await store.appSessionDocument(
                sessionID: context.session.sessionID
            )
            let currentState = document.map {
                ContextStore.section(
                    named: "Current state",
                    in: $0.markdown
                )
            } ?? ""
            let update = try await structurer.updateContextDocument(
                currentState: currentState,
                observations: pending
            )
            guard !suppressedSessions.contains(key) else { return }
            if update.changed {
                _ = try await store.applyAppSessionUpdate(
                    metadata: context.session,
                    update: update,
                    at: pending.last?.capturedAt ?? Date()
                )
            }
            failureCounts.removeValue(forKey: key)
            if closingSessions.contains(context.session.sessionID) {
                try? await store.closeAppSession(
                    sessionID: context.session.sessionID,
                    at: pending.last?.capturedAt ?? Date()
                )
            }
        } catch {
            if var latest = liveContexts[key] {
                latest.pendingObservations.insert(contentsOf: pending, at: 0)
                liveContexts[key] = latest
            }
            let count = (failureCounts[key] ?? 0) + 1
            failureCounts[key] = count
            if count >= 3, let context = liveContexts[key] {
                let fingerprint = pending.map {
                    "\($0.capturedAt.timeIntervalSinceReferenceDate):\($0.normalizedText)"
                }.joined(separator: "|")
                if unprocessedFailureBatches[key, default: []]
                    .insert(fingerprint).inserted {
                    _ = try? await store.appendUnprocessedObservations(
                        pending,
                        metadata: context.session,
                        at: pending.last?.capturedAt ?? Date()
                    )
                }
                failureCounts[key] = 0
            }
        }
    }

    private func flush(
        key: SessionKey,
        unprocessedOnFailure: Bool
    ) async {
        guard var context = liveContexts[key],
              !context.pendingObservations.isEmpty else {
            return
        }
        let pending = context.pendingObservations
        context.pendingObservations = []
        liveContexts[key] = context
        do {
            let document = await store.appSessionDocument(
                sessionID: context.session.sessionID
            )
            let currentState = document.map {
                ContextStore.section(named: "Current state", in: $0.markdown)
            } ?? ""
            let update = try await structurer.updateContextDocument(
                currentState: currentState,
                observations: pending
            )
            _ = try await store.applyAppSessionUpdate(
                metadata: context.session,
                update: update,
                at: pending.last?.capturedAt ?? Date()
            )
        } catch where unprocessedOnFailure {
            _ = try? await store.appendUnprocessedObservations(
                pending,
                metadata: context.session,
                at: pending.last?.capturedAt ?? Date()
            )
        } catch {
            context.pendingObservations = pending + context.pendingObservations
            liveContexts[key] = context
        }
    }

    private func rollPreviousDayIfNeeded(
        processIdentifier: pid_t,
        dayIdentifier: String,
        at date: Date
    ) async {
        let previousKeys = liveContexts.keys.filter {
            $0.processIdentifier == processIdentifier
                && $0.dayIdentifier != dayIdentifier
        }
        for key in previousKeys {
            if let context = liveContexts[key] {
                closingSessions.insert(context.session.sessionID)
            }
            await flush(key: key, unprocessedOnFailure: true)
            liveContexts.removeValue(forKey: key)
        }
        if !previousKeys.isEmpty {
            try? await store.closeAppSessions(
                processIdentifier: processIdentifier,
                at: date
            )
        }
    }

    private func makeSession(
        for observation: ContextObservation,
        dayIdentifier: String
    ) async -> AppSessionMetadata {
        let iconRelativePath = await cacheIcon(
            processIdentifier: observation.processIdentifier,
            bundleIdentifier: observation.bundleIdentifier
        )
        return AppSessionMetadata(
            applicationName: observation.applicationName,
            bundleIdentifier: observation.bundleIdentifier,
            processIdentifier: observation.processIdentifier,
            startedAt: observation.capturedAt,
            dayIdentifier: dayIdentifier,
            iconRelativePath: iconRelativePath,
            sources: Set(observation.blocks.map(\.source))
        )
    }

    private func cacheIcon(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) async -> String? {
        await MainActor.run {
            guard let application = NSRunningApplication(
                processIdentifier: processIdentifier
            ),
                  let icon = application.icon,
                  let tiff = icon.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            let slug = (bundleIdentifier ?? application.localizedName ?? "application")
                .replacingOccurrences(
                    of: #"[^A-Za-z0-9._-]"#,
                    with: "-",
                    options: .regularExpression
                )
            let filename = "\(slug).png"
            let url = store.appIconsDirectory.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(
                    at: store.appIconsDirectory,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    try png.write(to: url, options: .atomic)
                }
                return "App Icons/\(filename)"
            } catch {
                return nil
            }
        }
    }

    private static func merged(
        previous: ContextObservation?,
        incoming: ContextObservation
    ) -> ContextObservation {
        guard let previous else { return incoming }
        let incomingSources = Set(incoming.blocks.map(\.source))
        var blocks = previous.blocks.filter {
            !incomingSources.contains($0.source)
        } + incoming.blocks
        var seen: Set<String> = []
        blocks = blocks
            .sorted {
                if $0.source != $1.source {
                    return $0.source == .accessibility
                }
                return $0.confidence > $1.confidence
            }
            .filter { block in
                let normalized = ContextObservation.normalized(block.text)
                guard !normalized.isEmpty, !seen.contains(normalized) else {
                    return false
                }
                seen.insert(normalized)
                return true
            }
        return ContextObservation(
            capturedAt: incoming.capturedAt,
            processIdentifier: incoming.processIdentifier,
            bundleIdentifier: incoming.bundleIdentifier,
            applicationName: incoming.applicationName,
            windowIdentifier: incoming.windowIdentifier ?? previous.windowIdentifier,
            windowTitle: incoming.windowTitle ?? previous.windowTitle,
            displayIdentifier: incoming.displayIdentifier ?? previous.displayIdentifier,
            isFrontmost: incoming.isFrontmost,
            blocks: blocks
        )
    }

    private static func windowKey(for observation: ContextObservation) -> String {
        if let title = observation.windowTitle, !title.isEmpty {
            return "title:\(title)"
        }
        if let windowIdentifier = observation.windowIdentifier {
            return "window:\(windowIdentifier)"
        }
        return "untitled"
    }

    private static func render(_ observation: ContextObservation) -> String {
        let title = observation.windowTitle.map { "Window: \($0)\n" } ?? ""
        return title + observation.blocks.map(\.text).joined(separator: "\n")
    }

    private static func dayIdentifier(
        for date: Date,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
