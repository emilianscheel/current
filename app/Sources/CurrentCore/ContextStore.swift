import Foundation
import Observation

public struct ContextDocument: Identifiable, Sendable, Equatable {
    public let id: String
    public let date: Date
    public let url: URL
    public var markdown: String
    public let modifiedAt: Date

    public init(id: String, date: Date, url: URL, markdown: String, modifiedAt: Date) {
        self.id = id
        self.date = date
        self.url = url
        self.markdown = markdown
        self.modifiedAt = modifiedAt
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
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls {
                try migrateLegacyDocumentIfNeeded(at: url)
            }
            documents = try urls.compactMap(loadDocument)
                .sorted { $0.date > $1.date }
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
        try write(markdown, to: document.url)
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

    private func loadDocument(at url: URL) throws -> ContextDocument? {
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
            modifiedAt: values.contentModificationDate ?? .distantPast
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
