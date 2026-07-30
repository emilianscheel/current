import Foundation
import Observation

public enum ContextDocumentKind: Sendable, Equatable {
    case dailyDictation
    case appSession(AppSessionMetadata)
    case manual(ManualContextDocumentMetadata)
}

public enum ManualContextDocumentRole: String, Codable, Sendable, Equatable {
    case aboutMe
    case instructions
    case custom
}

public struct ManualContextDocumentMetadata: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let createdAt: Date
    public let role: ManualContextDocumentRole

    public init(
        id: String,
        title: String,
        createdAt: Date,
        role: ManualContextDocumentRole
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.role = role
    }

    public var isProtected: Bool { role != .custom }
}

public struct ContextDocument: Identifiable, Sendable, Equatable {
    public let id: String
    public let date: Date
    public let url: URL
    public var markdown: String
    public let modifiedAt: Date
    public let kind: ContextDocumentKind
    public let customDisplayName: String?

    public init(
        id: String,
        date: Date,
        url: URL,
        markdown: String,
        modifiedAt: Date,
        kind: ContextDocumentKind = .dailyDictation,
        customDisplayName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.url = url
        self.markdown = markdown
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.customDisplayName = customDisplayName
    }

    public var wordCount: Int {
        markdown.split(whereSeparator: { $0.isWhitespace }).count
    }

    fileprivate var appSessionMetadata: AppSessionMetadata? {
        guard case .appSession(let metadata) = kind else { return nil }
        return metadata
    }

    public var manualMetadata: ManualContextDocumentMetadata? {
        guard case .manual(let metadata) = kind else { return nil }
        return metadata
    }

    public var isProtected: Bool {
        manualMetadata?.isProtected == true
    }
}

@MainActor
@Observable
public final class ContextStore {
    private struct PersistedAppSession: Codable {
        var metadata: AppSessionMetadata
        var presentationVersion: Int
        var displayedThrough: Date
    }

    private struct DocumentMetadataFile: Codable {
        var version = 3
        var aliases: [String: String] = [:]
        var appSessions: [String: PersistedAppSession] = [:]
        var manualDocuments: [String: ManualContextDocumentMetadata] = [:]

        private enum CodingKeys: String, CodingKey {
            case version, aliases, appSessions, manualDocuments
        }

        init(
            aliases: [String: String] = [:],
            appSessions: [String: PersistedAppSession] = [:],
            manualDocuments: [String: ManualContextDocumentMetadata] = [:]
        ) {
            self.aliases = aliases
            self.appSessions = appSessions
            self.manualDocuments = manualDocuments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            aliases = try container.decodeIfPresent(
                [String: String].self,
                forKey: .aliases
            ) ?? [:]
            appSessions = try container.decodeIfPresent(
                [String: PersistedAppSession].self,
                forKey: .appSessions
            ) ?? [:]
            manualDocuments = try container.decodeIfPresent(
                [String: ManualContextDocumentMetadata].self,
                forKey: .manualDocuments
            ) ?? [:]
        }
    }

    public static let aboutMeDocumentID = "manual:about-me"
    public static let instructionsDocumentID = "manual:instructions"

    public private(set) var documents: [ContextDocument] = []
    public private(set) var lastError: String?

    public let directory: URL
    public var appSessionsDirectory: URL {
        directory.appendingPathComponent("App Sessions", isDirectory: true)
    }
    public var appIconsDirectory: URL {
        directory.appendingPathComponent("App Icons", isDirectory: true)
    }
    public var manualDocumentsDirectory: URL {
        directory.appendingPathComponent("Documents", isDirectory: true)
    }
    private var calendar: Calendar
    private let locale: Locale
    private let fileManager: FileManager
    private let trashHandler: ((URL) throws -> Void)?
    private var aliases: [String: String] = [:]
    private var persistedAppSessions: [String: PersistedAppSession] = [:]
    private var persistedManualDocuments: [String: ManualContextDocumentMetadata] = [:]
    private var metadataURL: URL {
        directory.appendingPathComponent("Document Metadata.json")
    }

    public init(
        directory: URL? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        fileManager: FileManager = .default,
        trashHandler: ((URL) throws -> Void)? = nil
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.calendar = calendar
        self.locale = locale
        self.fileManager = fileManager
        self.trashHandler = trashHandler
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Current", isDirectory: true)
            .appendingPathComponent("Context", isDirectory: true)
    }

    public func reload() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let persistedMetadata = loadDocumentMetadata()
            aliases = persistedMetadata.aliases
            persistedAppSessions = persistedMetadata.appSessions
            persistedManualDocuments = persistedMetadata.manualDocuments
            try ensureBuiltInManualDocuments()
            let rootURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let dailyURLs = rootURLs.filter { $0.pathExtension.lowercased() == "md" }
            for url in dailyURLs {
                try migrateLegacyDocumentIfNeeded(at: url)
            }
            var loaded = try dailyURLs.compactMap(loadDailyDocument)
            for metadata in persistedManualDocuments.values {
                if let document = try loadManualDocument(metadata: metadata) {
                    loaded.append(document)
                }
            }
            if fileManager.fileExists(atPath: appSessionsDirectory.path),
               let enumerator = fileManager.enumerator(
                   at: appSessionsDirectory,
                   includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                   options: [.skipsHiddenFiles]
               ) {
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                    if let document = try loadAppSessionDocument(at: url),
                       !Self.isExcludedAppSession(document) {
                        loaded.append(document)
                    }
                }
            }
            let sorted = chronologicallySorted(loaded)
            let standingIDs = [
                Self.aboutMeDocumentID,
                Self.instructionsDocumentID,
            ]
            documents = standingIDs.compactMap { id in
                sorted.first { $0.id == id }
            } + sorted.filter { !standingIDs.contains($0.id) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func isExcludedAppSession(
        _ document: ContextDocument
    ) -> Bool {
        guard case .appSession(let metadata) = document.kind else {
            return false
        }
        return metadata.bundleIdentifier.map(
            ContextApplicationExclusions.bundleIdentifiers.contains
        ) == true
    }

    @discardableResult
    public func append(_ transcription: String, at date: Date) throws -> ContextDocument {
        let text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ContextStoreError.emptyTranscription
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = documentID(for: date)
        let url = directory.appendingPathComponent(id).appendingPathExtension("md")
        var markdown: String
        if fileManager.fileExists(atPath: url.path) {
            markdown = try String(contentsOf: url, encoding: .utf8)
            markdown = migratedLegacyMarkdown(markdown, for: date) ?? markdown
        } else {
            markdown = ""
        }
        markdown = markdown.trimmingCharacters(in: .newlines)
        if !markdown.isEmpty { markdown += "\n\n" }
        markdown += "**\(displayTitle(for: date)) \(timeTitle(for: date)) h**\n"
            + "\(Self.escapedLiteralMarkdown(text))\n"
        try write(markdown, to: url)
        reload()
        guard let document = documents.first(where: { $0.id == id }) else {
            throw ContextStoreError.documentUnavailable
        }
        return document
    }

    public func save(documentID: String, markdown: String) throws {
        guard let document = documents.first(where: { $0.id == documentID }) else {
            throw ContextStoreError.documentUnavailable
        }
        switch document.kind {
        case .dailyDictation:
            try write(markdown, to: document.url)
        case .manual:
            try write(markdown, to: document.url)
        case .appSession(let metadata):
            try writeAppSession(
                metadata: metadata,
                currentState: Self.section(named: "Current state", in: markdown),
                activity: Self.section(named: "Activity", in: markdown),
                unprocessed: Self.section(
                    named: "Unprocessed observations",
                    in: markdown
                ),
                compact: isCompactAppSession(document),
                displayedThrough: persistedAppSessions[
                    metadata.sessionID.rawValue
                ]?.displayedThrough ?? metadata.endedAt ?? metadata.startedAt,
                to: document.url
            )
        }
        reload()
    }

    public func document(id: String) -> ContextDocument? {
        documents.first { $0.id == id }
    }

    public func filteredDocuments(matching query: String) -> [ContextDocument] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return documents }
        return chronologicallySorted(documents.filter { document in
            displayTitle(for: document.date).localizedStandardContains(needle)
                || document.id.localizedStandardContains(needle)
                || document.customDisplayName?
                    .localizedStandardContains(needle) == true
                || document.appSessionMetadata?.applicationName
                    .localizedStandardContains(needle) == true
                || document.appSessionMetadata?.bundleIdentifier?
                    .localizedStandardContains(needle) == true
                || document.markdown.localizedStandardContains(needle)
        })
    }

    @discardableResult
    public func createManualDocument(
        title: String,
        at date: Date = Date()
    ) throws -> ContextDocument {
        let normalized = try normalizedDisplayName(title)
        try fileManager.createDirectory(
            at: manualDocumentsDirectory,
            withIntermediateDirectories: true
        )
        let id = "manual:\(UUID().uuidString.lowercased())"
        let metadata = ManualContextDocumentMetadata(
            id: id,
            title: normalized,
            createdAt: date,
            role: .custom
        )
        let url = manualDocumentURL(for: metadata)
        try write("", to: url)
        persistedManualDocuments[id] = metadata
        do {
            try persistDocumentMetadata()
        } catch {
            try? fileManager.removeItem(at: url)
            persistedManualDocuments.removeValue(forKey: id)
            throw error
        }
        reload()
        guard let document = document(id: id) else {
            throw ContextStoreError.documentUnavailable
        }
        return document
    }

    public func standingPromptDocuments() -> [ContextDocument] {
        [Self.instructionsDocumentID, Self.aboutMeDocumentID].compactMap {
            document(id: $0)
        }
    }

    public func rename(documentID: String, displayName: String) throws {
        guard let document = document(id: documentID) else {
            throw ContextStoreError.documentUnavailable
        }
        let normalized = try normalizedDisplayName(displayName)
        if case .manual(var metadata) = document.kind {
            guard !metadata.isProtected else {
                throw ContextStoreError.protectedDocument
            }
            metadata.title = normalized
            persistedManualDocuments[documentID] = metadata
            try persistDocumentMetadata()
            reload()
            return
        }
        aliases[documentID] = normalized
        try persistAliases()
        reload()
    }

    public func moveToTrash(documentID: String) throws {
        guard let document = documents.first(where: { $0.id == documentID }) else {
            throw ContextStoreError.documentUnavailable
        }
        guard !document.isProtected else {
            throw ContextStoreError.protectedDocument
        }
        if let trashHandler {
            try trashHandler(document.url)
        } else {
            _ = try fileManager.trashItem(at: document.url, resultingItemURL: nil)
        }
        if aliases.removeValue(forKey: documentID) != nil {
            try persistDocumentMetadata()
        }
        if case .appSession(let metadata) = document.kind,
           persistedAppSessions.removeValue(
               forKey: metadata.sessionID.rawValue
           ) != nil {
            try persistDocumentMetadata()
        }
        if case .manual = document.kind,
           persistedManualDocuments.removeValue(forKey: documentID) != nil {
            try persistDocumentMetadata()
        }
        reload()
    }

    public func appSessionDocument(
        sessionID: AppSessionID
    ) -> ContextDocument? {
        documents.first {
            guard case .appSession(let metadata) = $0.kind else { return false }
            return metadata.sessionID == sessionID
        }
    }

    public func appSessionDocuments(
        bundleIdentifier: String? = nil,
        activeOnly: Bool = false
    ) -> [ContextDocument] {
        documents.filter { document in
            guard case .appSession(let metadata) = document.kind else { return false }
            if activeOnly, !metadata.isActive { return false }
            if let bundleIdentifier {
                return metadata.bundleIdentifier == bundleIdentifier
            }
            return true
        }
    }

    public func appSessionDocumentsRequiringMigration()
        -> [ContextDocument] {
        appSessionDocuments().filter {
            Self.tableValue("Session ID", in: $0.markdown) != nil
                && Self.tableValue("Format Version", in: $0.markdown) != "2"
        }
    }

    public func migrateAppSessionDocument(
        documentID: String,
        currentState: String,
        activity: String
    ) throws {
        guard let document = document(id: documentID),
              case .appSession(let metadata) = document.kind else {
            throw ContextStoreError.documentUnavailable
        }
        try writeAppSession(
            metadata: metadata,
            currentState: currentState,
            activity: activity,
            unprocessed: Self.section(
                named: "Unprocessed observations",
                in: document.markdown
            ),
            compact: isCompactAppSession(document),
            displayedThrough: persistedAppSessions[
                metadata.sessionID.rawValue
            ]?.displayedThrough ?? metadata.endedAt ?? metadata.startedAt,
            to: document.url
        )
        reload()
    }

    @discardableResult
    public func applyAppSessionUpdate(
        metadata: AppSessionMetadata,
        update: ContextDocumentUpdate,
        at date: Date = Date()
    ) throws -> ContextDocument {
        try fileManager.createDirectory(
            at: appSessionsDirectory.appendingPathComponent(metadata.dayIdentifier, isDirectory: true),
            withIntermediateDirectories: true
        )
        let existing = appSessionDocument(sessionID: metadata.sessionID)
        let url = existing?.url ?? appSessionURL(for: metadata)
        let existingMarkdown = existing?.markdown
            ?? (try? String(contentsOf: url, encoding: .utf8))
            ?? ""
        let compact = existing.map(isCompactAppSession) ?? true
        let currentState = ContextBulletNormalizer.bullets(
            update.currentStateMarkdown.components(separatedBy: .newlines),
            maximumCount: 24
        )
        .joined(separator: "\n")
        var activity = Self.section(
            named: "Activity",
            in: existingMarkdown
        )
        if let entryMarkdown = update.activityEntryMarkdown {
            let entry = ContextBulletNormalizer.bullets(
                entryMarkdown.components(separatedBy: .newlines),
                maximumCount: 12
            ).joined(separator: "\n")
            if !entry.isEmpty {
                if !activity.isEmpty { activity += "\n\n" }
                activity += "### \(timeWithSeconds(for: date))\n\n\(entry)"
            }
        }
        let unprocessed = Self.section(
            named: "Unprocessed observations",
            in: existingMarkdown
        )
        try writeAppSession(
            metadata: metadata,
            currentState: currentState,
            activity: activity,
            unprocessed: unprocessed,
            compact: compact,
            displayedThrough: date,
            to: url
        )
        reload()
        guard let document = appSessionDocument(sessionID: metadata.sessionID) else {
            throw ContextStoreError.documentUnavailable
        }
        return document
    }

    @discardableResult
    public func appendUnprocessedObservations(
        _ observations: [ContextObservation],
        metadata: AppSessionMetadata,
        at date: Date = Date()
    ) throws -> ContextDocument {
        let existing = appSessionDocument(sessionID: metadata.sessionID)
        let currentState = existing.map {
            Self.section(named: "Current state", in: $0.markdown)
        } ?? ""
        let activity = existing.map {
            Self.section(named: "Activity", in: $0.markdown)
        } ?? ""
        var unprocessed = existing.map {
            Self.section(named: "Unprocessed observations", in: $0.markdown)
        } ?? ""
        let text = observations.map { observation in
            let title = observation.windowTitle.map { " — \($0)" } ?? ""
            return "### \(timeWithSeconds(for: observation.capturedAt))\(title)\n\n"
                + observation.blocks.map(\.text).joined(separator: "\n")
        }.joined(separator: "\n\n")
        if !unprocessed.isEmpty, !text.isEmpty { unprocessed += "\n\n" }
        unprocessed += text
        let url = existing?.url ?? appSessionURL(for: metadata)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAppSession(
            metadata: metadata,
            currentState: currentState,
            activity: activity,
            unprocessed: unprocessed,
            compact: existing.map(isCompactAppSession) ?? true,
            displayedThrough: date,
            to: url
        )
        reload()
        guard let document = appSessionDocument(sessionID: metadata.sessionID) else {
            throw ContextStoreError.documentUnavailable
        }
        return document
    }

    public func closeAppSessions(
        processIdentifier: pid_t? = nil,
        at date: Date = Date()
    ) throws {
        let sessions = appSessionDocuments(activeOnly: true).compactMap { document
            -> (ContextDocument, AppSessionMetadata)? in
            guard case .appSession(let metadata) = document.kind,
                  processIdentifier == nil || metadata.processIdentifier == processIdentifier else {
                return nil
            }
            return (document, metadata)
        }
        for (document, var metadata) in sessions {
            metadata.endedAt = date
            try writeAppSession(
                metadata: metadata,
                currentState: Self.section(named: "Current state", in: document.markdown),
                activity: Self.section(named: "Activity", in: document.markdown),
                unprocessed: Self.section(
                    named: "Unprocessed observations",
                    in: document.markdown
                ),
                compact: isCompactAppSession(document),
                displayedThrough: date,
                to: document.url
            )
        }
        reload()
    }

    public func closeAppSession(
        sessionID: AppSessionID,
        at date: Date = Date()
    ) throws {
        guard let document = appSessionDocument(sessionID: sessionID),
              case .appSession(var metadata) = document.kind else {
            return
        }
        metadata.endedAt = date
        try writeAppSession(
            metadata: metadata,
            currentState: Self.section(named: "Current state", in: document.markdown),
            activity: Self.section(named: "Activity", in: document.markdown),
            unprocessed: Self.section(
                named: "Unprocessed observations",
                in: document.markdown
            ),
            compact: isCompactAppSession(document),
            displayedThrough: date,
            to: document.url
        )
        reload()
    }

    public func displayTitle(for date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    private func appSessionURL(for metadata: AppSessionMetadata) -> URL {
        let slug = Self.filenameSlug(
            metadata.bundleIdentifier ?? metadata.applicationName
        )
        let start = Self.filenameTimestamp(metadata.startedAt)
        let filename = "\(slug)--\(start)--\(metadata.processIdentifier)--\(metadata.sessionID.rawValue).md"
        return appSessionsDirectory
            .appendingPathComponent(metadata.dayIdentifier, isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func writeAppSession(
        metadata: AppSessionMetadata,
        currentState: String,
        activity: String,
        unprocessed: String,
        compact: Bool,
        displayedThrough: Date,
        to url: URL
    ) throws {
        if compact {
            persistedAppSessions[metadata.sessionID.rawValue] =
                PersistedAppSession(
                    metadata: metadata,
                    presentationVersion: 3,
                    displayedThrough: displayedThrough
                )
            try persistDocumentMetadata()
        }
        let markdown = compact
            ? compactAppSessionMarkdown(
                metadata: metadata,
                currentState: currentState,
                activity: activity,
                unprocessed: unprocessed,
                displayedThrough: displayedThrough
            )
            : legacyAppSessionMarkdown(
                metadata: metadata,
                currentState: currentState,
                activity: activity,
                unprocessed: unprocessed
            )
        try write(markdown, to: url)
    }

    private func legacyAppSessionMarkdown(
        metadata: AppSessionMetadata,
        currentState: String,
        activity: String,
        unprocessed: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let ended = metadata.endedAt.map(formatter.string) ?? "Active"
        let bundleIdentifier = metadata.bundleIdentifier ?? ""
        let icon = metadata.iconRelativePath ?? ""
        let sources = metadata.sources
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        var markdown = """
        # \(Self.tableEscaped(metadata.applicationName)) — App Session

        | Metadata | Value |
        | --- | --- |
        | Format Version | 2 |
        | App | \(Self.tableEscaped(metadata.applicationName)) |
        | Bundle ID | \(Self.tableEscaped(bundleIdentifier)) |
        | Session ID | \(metadata.sessionID.rawValue) |
        | Process ID | \(metadata.processIdentifier) |
        | Started | \(formatter.string(from: metadata.startedAt)) |
        | Ended | \(ended) |
        | Day | \(metadata.dayIdentifier) |
        | Icon | \(Self.tableEscaped(icon)) |
        | Sources | \(sources) |

        ## Current state

        \(currentState)

        ## Activity

        \(activity)
        """
        if !unprocessed.isEmpty {
            markdown += "\n\n## Unprocessed observations\n\n\(unprocessed)"
        }
        return markdown.trimmingCharacters(in: .newlines) + "\n"
    }

    private func compactAppSessionMarkdown(
        metadata: AppSessionMetadata,
        currentState: String,
        activity: String,
        unprocessed: String,
        displayedThrough: Date
    ) -> String {
        var body: [String] = currentState
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        body.append(contentsOf: compactHistoryLines(from: activity))
        body.append(contentsOf: compactHistoryLines(from: unprocessed))

        let title = Self.escapedBoldMarkdown(metadata.applicationName)
        let displayLine = sessionDisplayLine(
            metadata: metadata,
            displayedThrough: displayedThrough
        )
        var markdown = "**\(title)**\n\(displayLine)\n"
        if !body.isEmpty {
            markdown += "\n" + body.joined(separator: "\n")
        }
        return markdown.trimmingCharacters(in: .newlines) + "\n"
    }

    private func compactHistoryLines(from markdown: String) -> [String] {
        var output: [String] = []
        var timestamp: String?
        var context: String?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("### ") {
                let heading = String(line.dropFirst(4))
                timestamp = String(heading.prefix(5))
                var remainder = heading.dropFirst(min(8, heading.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix("—") {
                    remainder = String(remainder.dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                }
                context = remainder.isEmpty ? nil : remainder
                continue
            }
            guard !line.isEmpty, let timestamp else { continue }
            let content = Self.removingBulletPrefix(from: line)
            guard !content.isEmpty else { continue }
            let prefix = context.map { "\($0) — " } ?? ""
            output.append("\(timestamp) — \(prefix)\(content)")
        }
        return output
    }

    private func sessionDisplayLine(
        metadata: AppSessionMetadata,
        displayedThrough: Date
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none

        let end = metadata.endedAt
        let endLabel = end.map { timeTitle(for: $0) } ?? "Active"
        let elapsedTo = max(metadata.startedAt, end ?? displayedThrough)
        let elapsedMinutes = max(
            0,
            Int(elapsedTo.timeIntervalSince(metadata.startedAt) / 60)
        )
        let durationFormatter = DateComponentsFormatter()
        var durationCalendar = calendar
        durationCalendar.locale = locale
        durationFormatter.calendar = durationCalendar
        durationFormatter.allowedUnits = elapsedMinutes >= 60
            ? [.hour, .minute]
            : [.minute]
        durationFormatter.unitsStyle = .short
        durationFormatter.maximumUnitCount = 2
        let duration = durationFormatter.string(
            from: TimeInterval(elapsedMinutes * 60)
        )?.replacingOccurrences(of: ", ", with: " ") ?? "0 min"
        return "\(dateFormatter.string(from: metadata.startedAt)), "
            + "\(timeTitle(for: metadata.startedAt))–\(endLabel) (\(duration))"
    }

    private func loadAppSessionDocument(at url: URL) throws -> ContextDocument? {
        let values = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else { return nil }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        if let persisted = persistedSession(for: url, markdown: markdown) {
            guard let date = date(fromDocumentID: persisted.metadata.dayIdentifier) else {
                return nil
            }
            let id = "app:\(persisted.metadata.sessionID.rawValue)"
            return ContextDocument(
                id: id,
                date: date,
                url: url,
                markdown: markdown,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                kind: .appSession(persisted.metadata),
                customDisplayName: aliases[id]
            )
        }
        guard let sessionID = Self.tableValue("Session ID", in: markdown),
              let appName = Self.tableValue("App", in: markdown),
              let processString = Self.tableValue("Process ID", in: markdown),
              let processIdentifier = pid_t(processString),
              let startedString = Self.tableValue("Started", in: markdown),
              let startedAt = ISO8601DateFormatter().date(from: startedString),
              let dayIdentifier = Self.tableValue("Day", in: markdown),
              let date = date(fromDocumentID: dayIdentifier) else {
            return nil
        }
        let endedString = Self.tableValue("Ended", in: markdown)
        let endedAt = endedString.flatMap {
            $0 == "Active" ? nil : ISO8601DateFormatter().date(from: $0)
        }
        let bundle = Self.tableValue("Bundle ID", in: markdown)
        let icon = Self.tableValue("Icon", in: markdown)
        let sources = Set(
            (Self.tableValue("Sources", in: markdown) ?? "")
                .split(separator: ",")
                .compactMap { ContextSource(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        )
        let metadata = AppSessionMetadata(
            sessionID: AppSessionID(rawValue: sessionID),
            applicationName: appName,
            bundleIdentifier: bundle?.isEmpty == false ? bundle : nil,
            processIdentifier: processIdentifier,
            startedAt: startedAt,
            endedAt: endedAt,
            dayIdentifier: dayIdentifier,
            iconRelativePath: icon?.isEmpty == false ? icon : nil,
            sources: sources
        )
        return ContextDocument(
            id: "app:\(sessionID)",
            date: date,
            url: url,
            markdown: markdown,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            kind: .appSession(metadata),
            customDisplayName: aliases["app:\(sessionID)"]
        )
    }

    private func persistedSession(
        for url: URL,
        markdown: String
    ) -> PersistedAppSession? {
        let filename = url.deletingPathExtension().lastPathComponent
        let sessionID = filename.components(separatedBy: "--").last
        if let sessionID,
           let persisted = persistedAppSessions[sessionID],
           persisted.presentationVersion >= 3 {
            return persisted
        }
        return recoveredCompactSession(for: url, markdown: markdown)
    }

    private func isCompactAppSession(_ document: ContextDocument) -> Bool {
        guard case .appSession(let metadata) = document.kind else {
            return false
        }
        return (persistedAppSessions[metadata.sessionID.rawValue]?
            .presentationVersion ?? 0) >= 3
            || document.markdown.hasPrefix("**")
    }

    private func recoveredCompactSession(
        for url: URL,
        markdown: String
    ) -> PersistedAppSession? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let titleLine = lines.first,
              titleLine.hasPrefix("**"), titleLine.hasSuffix("**"),
              lines.count >= 2 else {
            return nil
        }
        let parts = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: "--")
        guard parts.count == 4,
              let startedAt = Self.filenameDate(parts[1]),
              let processIdentifier = pid_t(parts[2]) else {
            return nil
        }
        let dayIdentifier = url.deletingLastPathComponent().lastPathComponent
        let applicationName = String(titleLine.dropFirst(2).dropLast(2))
            .replacingOccurrences(of: "\\*", with: "*")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\\\", with: "\\")
        let metadata = AppSessionMetadata(
            sessionID: AppSessionID(rawValue: parts[3]),
            applicationName: applicationName,
            bundleIdentifier: nil,
            processIdentifier: processIdentifier,
            startedAt: startedAt,
            endedAt: lines[1].contains("–Active") ? nil : startedAt,
            dayIdentifier: dayIdentifier
        )
        return PersistedAppSession(
            metadata: metadata,
            presentationVersion: 3,
            displayedThrough: startedAt
        )
    }

    private static func tableValue(_ key: String, in markdown: String) -> String? {
        let prefix = "| \(key) |"
        guard let line = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        var value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("|") {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value.replacingOccurrences(of: "\\|", with: "|")
    }

    public nonisolated static func section(
        named name: String,
        in markdown: String
    ) -> String {
        let marker = "## \(name)"
        guard let start = markdown.range(of: marker) else {
            return compactSection(named: name, in: markdown)
        }
        let contentStart = start.upperBound
        let remainder = markdown[contentStart...]
        let end = remainder.range(of: "\n## ")?.lowerBound ?? markdown.endIndex
        return String(markdown[contentStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func compactSection(
        named name: String,
        in markdown: String
    ) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.hasPrefix("**") == true, lines.count >= 3 else {
            return ""
        }
        let body = lines.dropFirst(3).filter { !$0.isEmpty }
        let historyStart = body.firstIndex(where: isCompactHistoryLine)
            ?? body.endIndex
        if name == "Current state" {
            return body[..<historyStart].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "Activity" {
            return body[historyStart...].compactMap { line -> String? in
                guard isCompactHistoryLine(line), line.count > 8 else {
                    return nil
                }
                let time = line.prefix(5)
                let content = line.dropFirst(8)
                return "### \(time)\n\n- \(content)"
            }.joined(separator: "\n\n")
        }
        return ""
    }

    private nonisolated static func isCompactHistoryLine(_ line: String) -> Bool {
        line.range(
            of: #"^\d{2}:\d{2} — .+"#,
            options: .regularExpression
        ) != nil
    }

    private static func tableEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapedBoldMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func removingBulletPrefix(from value: String) -> String {
        for prefix in ["- ", "* ", "+ ", "• "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func filenameSlug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let slug = value.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        return String(slug)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func filenameDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value)
    }

    public nonisolated static func escapedLiteralMarkdown(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var escaped = String(line)
                for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "|", "~"] {
                    escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
                }
                if escaped.hasPrefix("- ") || escaped.hasPrefix("+ ") {
                    escaped.insert("\\", at: escaped.startIndex)
                } else if escaped.range(of: #"^\d+\. "#, options: .regularExpression) != nil,
                          let period = escaped.firstIndex(of: ".") {
                    escaped.insert("\\", at: period)
                }
                return escaped
            }
            .joined(separator: "\n")
    }

    private func ensureBuiltInManualDocuments() throws {
        try fileManager.createDirectory(
            at: manualDocumentsDirectory,
            withIntermediateDirectories: true
        )
        let hardware = HardwareChecker().current()
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: hardware.memoryBytes),
            countStyle: .memory
        )
        let fullName = NSFullUserName()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutMe = """
        - Name: \(fullName.isEmpty ? NSUserName() : fullName)
        - Mac: \(hardware.modelName)
        - Memory: \(memory)
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        let instructions = """
        Current is a local macOS voice dictation and writing tool. When a spoken request is a prompt, generate only the final text that should be pasted into the active app.

        - Follow the user's spoken instruction.
        - Use About me and the available application context when relevant.
        - Match the requested language, tone, and format.
        - Preserve names, dates, numbers, URLs, and known facts.
        - Do not mention the context, these instructions, or your reasoning.
        - Do not invent missing facts.
        """
        var metadataChanged = false
        for definition in [
            (
                id: Self.aboutMeDocumentID,
                title: "About me",
                role: ManualContextDocumentRole.aboutMe,
                markdown: aboutMe
            ),
            (
                id: Self.instructionsDocumentID,
                title: "Instructions",
                role: ManualContextDocumentRole.instructions,
                markdown: instructions
            ),
        ] {
            let existing = persistedManualDocuments[definition.id]
            let metadata = ManualContextDocumentMetadata(
                id: definition.id,
                title: definition.title,
                createdAt: existing?.createdAt ?? Date(),
                role: definition.role
            )
            if existing != metadata {
                persistedManualDocuments[definition.id] = metadata
                metadataChanged = true
            }
            let url = manualDocumentURL(for: metadata)
            if !fileManager.fileExists(atPath: url.path) {
                try write(definition.markdown + "\n", to: url)
            }
        }
        if metadataChanged {
            try persistDocumentMetadata()
        }
    }

    private func loadManualDocument(
        metadata: ManualContextDocumentMetadata
    ) throws -> ContextDocument? {
        let url = manualDocumentURL(for: metadata)
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        guard values?.isRegularFile == true else { return nil }
        return ContextDocument(
            id: metadata.id,
            date: metadata.createdAt,
            url: url,
            markdown: try String(contentsOf: url, encoding: .utf8),
            modifiedAt: values?.contentModificationDate ?? metadata.createdAt,
            kind: .manual(metadata),
            customDisplayName: metadata.title
        )
    }

    private func manualDocumentURL(
        for metadata: ManualContextDocumentMetadata
    ) -> URL {
        let filename = switch metadata.role {
        case .aboutMe: "About me"
        case .instructions: "Instructions"
        case .custom:
            String(metadata.id.dropFirst("manual:".count))
        }
        return manualDocumentsDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("md")
    }

    private func chronologicallySorted(
        _ input: [ContextDocument]
    ) -> [ContextDocument] {
        input.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.id < $1.id
        }
    }

    private func normalizedDisplayName(_ displayName: String) throws -> String {
        let normalized = displayName
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 120 else {
            throw ContextStoreError.invalidDisplayName
        }
        return normalized
    }

    private func loadDailyDocument(at url: URL) throws -> ContextDocument? {
        guard url.pathExtension.lowercased() == "md",
              let date = date(fromDocumentID: url.deletingPathExtension().lastPathComponent) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        return ContextDocument(
            id: url.deletingPathExtension().lastPathComponent,
            date: date,
            url: url,
            markdown: try String(contentsOf: url, encoding: .utf8),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            kind: .dailyDictation,
            customDisplayName: aliases[
                url.deletingPathExtension().lastPathComponent
            ]
        )
    }

    private func loadDocumentMetadata() -> DocumentMetadataFile {
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL) else {
            return DocumentMetadataFile()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DocumentMetadataFile.self, from: data))
            ?? DocumentMetadataFile()
    }

    private func persistAliases() throws {
        try persistDocumentMetadata()
    }

    private func persistDocumentMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            DocumentMetadataFile(
                aliases: aliases,
                appSessions: persistedAppSessions,
                manualDocuments: persistedManualDocuments
            )
        ).write(to: metadataURL, options: .atomic)
    }

    private func migrateLegacyDocumentIfNeeded(at url: URL) throws {
        guard url.pathExtension.lowercased() == "md",
              let date = date(fromDocumentID: url.deletingPathExtension().lastPathComponent) else {
            return
        }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        guard let migrated = migratedLegacyMarkdown(markdown, for: date) else { return }
        try write(migrated, to: url)
    }

    func migratedLegacyMarkdown(_ markdown: String, for date: Date) -> String? {
        var lines = markdown.components(separatedBy: .newlines)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.first == "# \(displayTitle(for: date))" else { return nil }

        var index = 1
        var entries: [(time: String, text: String)] = []
        while index < lines.count {
            while index < lines.count, lines[index].isEmpty { index += 1 }
            guard index < lines.count, lines[index].hasPrefix("## ") else { return nil }
            let legacyTime = String(lines[index].dropFirst(3))
            guard let time = normalizedLegacyTime(legacyTime, on: date) else { return nil }
            index += 1
            guard index < lines.count, lines[index].isEmpty else { return nil }
            while index < lines.count, lines[index].isEmpty { index += 1 }

            let textStart = index
            while index < lines.count, !lines[index].hasPrefix("## ") { index += 1 }
            var textLines = Array(lines[textStart..<index])
            while textLines.last?.isEmpty == true { textLines.removeLast() }
            guard !textLines.isEmpty else { return nil }
            entries.append((time, textLines.joined(separator: "\n")))
        }
        guard !entries.isEmpty else { return nil }

        return entries.map { entry in
            "\(displayTitle(for: date)) \(entry.time) h **\(entry.text)**"
        }.joined(separator: "\n\n") + "\n"
    }

    private func write(_ markdown: String, to url: URL) throws {
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    private func documentID(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func date(fromDocumentID id: String) -> Date? {
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    private func timeTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func timeWithSeconds(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func normalizedLegacyTime(_ value: String, on date: Date) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        guard let parsed = formatter.date(from: value) else { return nil }
        let components = calendar.dateComponents([.hour, .minute], from: parsed)
        guard let hour = components.hour, let minute = components.minute,
              let combined = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else {
            return nil
        }
        return timeTitle(for: combined)
    }
}

public enum ContextStoreError: LocalizedError, Sendable, Equatable {
    case emptyTranscription
    case documentUnavailable
    case invalidDisplayName
    case protectedDocument

    public var errorDescription: String? {
        switch self {
        case .emptyTranscription: "The transcription was empty."
        case .documentUnavailable: "The context document is no longer available."
        case .invalidDisplayName:
            "Choose a name between 1 and 120 characters."
        case .protectedDocument:
            "About me and Instructions cannot be renamed or moved to Trash."
        }
    }
}
