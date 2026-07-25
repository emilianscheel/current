import Foundation
import Observation

public enum ContextDocumentKind: Sendable, Equatable {
    case dailyDictation
    case appSession(AppSessionMetadata)
}

public struct ContextDocument: Identifiable, Sendable, Equatable {
    public let id: String
    public let date: Date
    public let url: URL
    public var markdown: String
    public let modifiedAt: Date
    public let kind: ContextDocumentKind

    public init(
        id: String,
        date: Date,
        url: URL,
        markdown: String,
        modifiedAt: Date,
        kind: ContextDocumentKind = .dailyDictation
    ) {
        self.id = id
        self.date = date
        self.url = url
        self.markdown = markdown
        self.modifiedAt = modifiedAt
        self.kind = kind
    }

    public var wordCount: Int {
        markdown.split(whereSeparator: { $0.isWhitespace }).count
    }
}

@MainActor
@Observable
public final class ContextStore {
    public private(set) var documents: [ContextDocument] = []
    public private(set) var lastError: String?

    public let directory: URL
    public var appSessionsDirectory: URL {
        directory.appendingPathComponent("App Sessions", isDirectory: true)
    }
    public var appIconsDirectory: URL {
        directory.appendingPathComponent("App Icons", isDirectory: true)
    }
    private var calendar: Calendar
    private let locale: Locale
    private let fileManager: FileManager
    private let trashHandler: ((URL) throws -> Void)?

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
            if fileManager.fileExists(atPath: appSessionsDirectory.path),
               let enumerator = fileManager.enumerator(
                   at: appSessionsDirectory,
                   includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                   options: [.skipsHiddenFiles]
               ) {
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                    if let document = try loadAppSessionDocument(at: url) {
                        loaded.append(document)
                    }
                }
            }
            documents = loaded.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.modifiedAt > $1.modifiedAt
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
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
        markdown += "\(displayTitle(for: date)) \(timeTitle(for: date)) h **\(Self.escapedLiteralMarkdown(text))**\n"
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
        case .appSession(let metadata):
            try write(
                appSessionMarkdown(
                    metadata: metadata,
                    currentState: Self.section(named: "Current state", in: markdown),
                    activity: Self.section(named: "Activity", in: markdown),
                    unprocessed: Self.section(
                        named: "Unprocessed observations",
                        in: markdown
                    )
                ),
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
        return documents.filter { document in
            displayTitle(for: document.date).localizedStandardContains(needle)
                || document.id.localizedStandardContains(needle)
                || document.markdown.localizedStandardContains(needle)
        }
    }

    public func moveToTrash(documentID: String) throws {
        guard let document = documents.first(where: { $0.id == documentID }) else {
            throw ContextStoreError.documentUnavailable
        }
        if let trashHandler {
            try trashHandler(document.url)
        } else {
            _ = try fileManager.trashItem(at: document.url, resultingItemURL: nil)
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
        let currentState = update.currentStateMarkdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var activity = Self.section(
            named: "Activity",
            in: existingMarkdown
        )
        if let entry = update.activityEntryMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !entry.isEmpty {
            if !activity.isEmpty { activity += "\n\n" }
            activity += "### \(timeWithSeconds(for: date))\n\n\(entry)"
        }
        let unprocessed = Self.section(
            named: "Unprocessed observations",
            in: existingMarkdown
        )
        let markdown = appSessionMarkdown(
            metadata: metadata,
            currentState: currentState,
            activity: activity,
            unprocessed: unprocessed
        )
        try write(markdown, to: url)
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
        try write(
            appSessionMarkdown(
                metadata: metadata,
                currentState: currentState,
                activity: activity,
                unprocessed: unprocessed
            ),
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
            try write(
                appSessionMarkdown(
                    metadata: metadata,
                    currentState: Self.section(named: "Current state", in: document.markdown),
                    activity: Self.section(named: "Activity", in: document.markdown),
                    unprocessed: Self.section(
                        named: "Unprocessed observations",
                        in: document.markdown
                    )
                ),
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
        try write(
            appSessionMarkdown(
                metadata: metadata,
                currentState: Self.section(named: "Current state", in: document.markdown),
                activity: Self.section(named: "Activity", in: document.markdown),
                unprocessed: Self.section(
                    named: "Unprocessed observations",
                    in: document.markdown
                )
            ),
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

    private func appSessionMarkdown(
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

    private func loadAppSessionDocument(at url: URL) throws -> ContextDocument? {
        let values = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else { return nil }
        let markdown = try String(contentsOf: url, encoding: .utf8)
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
            kind: .appSession(metadata)
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
        guard let start = markdown.range(of: marker) else { return "" }
        let contentStart = start.upperBound
        let remainder = markdown[contentStart...]
        let end = remainder.range(of: "\n## ")?.lowerBound ?? markdown.endIndex
        return String(markdown[contentStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
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
            kind: .dailyDictation
        )
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

    public var errorDescription: String? {
        switch self {
        case .emptyTranscription: "The transcription was empty."
        case .documentUnavailable: "The context document is no longer available."
        }
    }
}
