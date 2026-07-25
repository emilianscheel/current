import AppKit
import Foundation

public actor ContextRepository {
    private struct SessionKey: Hashable {
        let processIdentifier: pid_t
        let dayIdentifier: String
    }

    private let store: ContextStore
    private let intelligence: any LocalIntelligenceProviding
    private let excludedBundleIdentifiers: Set<String>
    private let excludedProcessIdentifiers: Set<pid_t>
    private var calendar: Calendar
    private var liveContexts: [SessionKey: LiveAppContext] = [:]
    private var processingSessions: Set<SessionKey> = []
    private var closingSessions: Set<AppSessionID> = []

    public init(
        store: ContextStore,
        intelligence: any LocalIntelligenceProviding,
        calendar: Calendar = .autoupdatingCurrent,
        excludedBundleIdentifiers: Set<String> = ["local.Current"],
        excludedProcessIdentifiers: Set<pid_t> = [
            ProcessInfo.processInfo.processIdentifier,
        ]
    ) {
        self.store = store
        self.intelligence = intelligence
        self.calendar = calendar
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludedProcessIdentifiers = excludedProcessIdentifiers
    }

    @discardableResult
    public func accept(_ observation: ContextObservation) async -> Bool {
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
        scheduleProcessing(for: key)
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
        }
        try? await store.closeAppSessions(
            processIdentifier: processIdentifier,
            at: date
        )
    }

    public func stop(at date: Date = Date()) async {
        for key in Array(liveContexts.keys) {
            if let context = liveContexts[key] {
                closingSessions.insert(context.session.sessionID)
            }
            await flush(key: key, unprocessedOnFailure: true)
        }
        try? await store.closeAppSessions(at: date)
        processingSessions.removeAll()
    }

    private func scheduleProcessing(for key: SessionKey) {
        guard !processingSessions.contains(key) else { return }
        processingSessions.insert(key)
        Task { [weak self] in
            await self?.processPending(for: key)
        }
    }

    private func processPending(for key: SessionKey) async {
        defer { processingSessions.remove(key) }
        while var context = liveContexts[key],
              !context.pendingObservations.isEmpty {
            let pending = context.pendingObservations
            context.pendingObservations = []
            liveContexts[key] = context
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
                let update = try await intelligence.updateContextDocument(
                    currentState: currentState,
                    observations: pending
                )
                if update.changed {
                    _ = try await store.applyAppSessionUpdate(
                        metadata: context.session,
                        update: update,
                        at: pending.last?.capturedAt ?? Date()
                    )
                }
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
                await flush(key: key, unprocessedOnFailure: true)
                return
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
            let update = try await intelligence.updateContextDocument(
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
