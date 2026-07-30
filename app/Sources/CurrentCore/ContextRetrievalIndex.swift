import CSQLite
import CryptoKit
import Foundation
import NaturalLanguage
import OSLog

public struct RetrievedContextChunk: Sendable, Equatable, Identifiable {
    public let id: String
    public let documentID: String
    public let title: String
    public let content: String
    public let modifiedAt: Date
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let ordinal: Int
    public let score: Double
}

/// A deliberately small, local retrieval index. SQLite FTS5 provides exact
/// lexical recall while an in-memory mirror keeps the feature functional if an
/// OS SQLite build does not expose FTS5.
public actor ContextRetrievalIndex {
    public static let schemaVersion = 2
    public static let maximumChunkWords = 480
    public static let overlapWords = 64
    public static let candidateLimit = 20
    public static let resultLimit = 6

    private struct Chunk: Sendable {
        let id: String
        let documentID: String
        let title: String
        let content: String
        let modifiedAt: Date
        let applicationName: String?
        let bundleIdentifier: String?
        let ordinal: Int
    }

    private let databaseURL: URL?
    private var database: OpaquePointer?
    private var didInitializeDatabase = false
    private var fingerprints: [String: String] = [:]
    private var chunks: [String: Chunk] = [:]
    private var semanticModel: NLContextualEmbedding?
    private var semanticVectors: [String: [Float]] = [:]
    private var didRequestSemanticAssets = false
    private let signposter = OSSignposter(
        subsystem: "com.emilianscheel.current",
        category: "ContextRetrieval"
    )

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    public func synchronize(
        documents: [ContextDocument],
        buildSemanticVectors: Bool = false
    ) throws {
        try initializeDatabaseIfNeeded()
        if buildSemanticVectors { prepareSemanticModelIfAvailable() }
        let searchable = documents.filter { document in
            guard let role = document.manualMetadata?.role else { return true }
            return role == .custom
        }
        let currentIDs = Set(searchable.map(\.id))
        for removed in Set(fingerprints.keys).subtracting(currentIDs) {
            fingerprints.removeValue(forKey: removed)
            semanticVectors = semanticVectors.filter { !$0.key.hasPrefix("\(removed):") }
            chunks = chunks.filter { $0.value.documentID != removed }
            try delete(documentID: removed)
        }

        for document in searchable {
            let fingerprint = Self.hash(document.markdown)
            guard fingerprints[document.id] != fingerprint else { continue }
            let replacements = Self.chunks(for: document)
            try delete(documentID: document.id)
            for chunk in replacements {
                chunks[chunk.id] = chunk
                try insert(chunk)
                if buildSemanticVectors,
                   semanticVectors[chunk.id] == nil,
                   let vector = semanticVector(for: chunk.content) {
                    semanticVectors[chunk.id] = vector
                    try store(vector: vector, chunkID: chunk.id)
                }
            }
            fingerprints[document.id] = fingerprint
        }
    }

    public func retrieve(
        query: String,
        target: ContextCaptureTarget? = nil,
        limit: Int = resultLimit
    ) throws -> [RetrievedContextChunk] {
        let interval = signposter.beginInterval("Bounded context retrieval")
        defer { signposter.endInterval("Bounded context retrieval", interval) }
        if !semanticVectors.isEmpty { prepareSemanticModelIfAvailable() }
        let terms = Self.queryTerms(query)
        let lexical = try sqliteCandidates(terms: terms)
        let lexicalRanks: [(String, Int)] = lexical.isEmpty
            ? fallbackCandidates(terms: terms).enumerated().map {
                ($0.element.id, $0.offset + 1)
            }
            : lexical
        let semanticRanks = semanticCandidates(query: query)
        var fused: [String: Double] = [:]
        for (id, rank) in lexicalRanks { fused[id, default: 0] += 1 / Double(60 + rank) }
        for (id, rank) in semanticRanks { fused[id, default: 0] += 1 / Double(60 + rank) }
        let now = Date()
        let ranked = fused.compactMap { id, fusedScore -> RetrievedContextChunk? in
            guard let chunk = chunks[id] else { return nil }
            var score = fusedScore
            if let target {
                if chunk.bundleIdentifier == target.bundleIdentifier { score += 0.020 }
                else if chunk.applicationName == target.applicationName { score += 0.012 }
            }
            let ageDays = max(0, now.timeIntervalSince(chunk.modifiedAt) / 86_400)
            score += 0.008 / (1 + ageDays / 7)
            return RetrievedContextChunk(
                id: chunk.id,
                documentID: chunk.documentID,
                title: chunk.title,
                content: chunk.content,
                modifiedAt: chunk.modifiedAt,
                applicationName: chunk.applicationName,
                bundleIdentifier: chunk.bundleIdentifier,
                ordinal: chunk.ordinal,
                score: score
            )
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.modifiedAt > rhs.modifiedAt : lhs.score > rhs.score
        }
        var selected: [RetrievedContextChunk] = []
        let boundedLimit = max(1, min(Self.resultLimit, limit))
        for candidate in ranked {
            let overlaps = selected.contains {
                $0.documentID == candidate.documentID
                    && abs($0.ordinal - candidate.ordinal) <= 1
            }
            guard !overlaps else { continue }
            selected.append(candidate)
            if selected.count == boundedLimit { break }
        }
        return selected
    }

    public func corpusOverview(maximumCharacters: Int = 24_000) -> String {
        let grouped = Dictionary(grouping: chunks.values, by: \.documentID)
        var result = ""
        for group in grouped.values.sorted(by: {
            ($0.first?.modifiedAt ?? .distantPast) > ($1.first?.modifiedAt ?? .distantPast)
        }) {
            guard let first = group.first else { continue }
            let content = group.sorted(by: { $0.ordinal < $1.ordinal })
                .map(\.content).joined(separator: "\n")
            let section = "Document: \(first.title)\n\(String(content.prefix(2_000)))"
            let separator = result.isEmpty ? "" : "\n\n"
            guard result.count + separator.count + section.count <= maximumCharacters else {
                break
            }
            result += separator + section
        }
        return result
    }

    public func indexedChunkCount() -> Int { chunks.count }

    private func initializeDatabaseIfNeeded() throws {
        guard !didInitializeDatabase else { return }
        didInitializeDatabase = true
        let path = databaseURL?.path ?? ":memory:"
        if let databaseURL {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return }
        database = handle
        if Self.userVersion(database: handle) != Self.schemaVersion {
            _ = sqlite3_exec(
                handle,
                "DROP TABLE IF EXISTS context_chunks; DROP TABLE IF EXISTS context_vectors;",
                nil,
                nil,
                nil
            )
            fingerprints.removeAll()
            chunks.removeAll()
            semanticVectors.removeAll()
        }
        let schema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS context_chunks USING fts5(
            chunk_id UNINDEXED,
            document_id UNINDEXED,
            title,
            content,
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS context_vectors(
            chunk_id TEXT PRIMARY KEY,
            vector BLOB NOT NULL
        );
        PRAGMA user_version=\(Self.schemaVersion);
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle)
            database = nil
        } else {
            loadStoredVectors()
        }
    }

    private func delete(documentID: String) throws {
        guard let database else { return }
        try execute(
            "DELETE FROM context_chunks WHERE document_id = ?",
            bindings: [documentID],
            database: database
        )
        try execute(
            "DELETE FROM context_vectors WHERE chunk_id LIKE ?",
            bindings: ["\(documentID):%"],
            database: database
        )
    }

    private func insert(_ chunk: Chunk) throws {
        guard let database else { return }
        try execute(
            "INSERT INTO context_chunks(chunk_id, document_id, title, content) VALUES(?, ?, ?, ?)",
            bindings: [chunk.id, chunk.documentID, chunk.title, chunk.content],
            database: database
        )
    }

    private func sqliteCandidates(terms: [String]) throws -> [(String, Int)] {
        guard let database, !terms.isEmpty else { return [] }
        let expression = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT chunk_id FROM context_chunks WHERE context_chunks MATCH ? ORDER BY bm25(context_chunks, 0, 0, 2, 1) LIMIT 20",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, expression, -1, Self.transient)
        var result: [(String, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            result.append((String(cString: value), result.count + 1))
        }
        return result
    }

    private func fallbackCandidates(terms: [String]) -> [Chunk] {
        var scored: [(chunk: Chunk, matches: Int)] = []
        for chunk in chunks.values {
            let haystack = (chunk.title + " " + chunk.content).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            var matches = 0
            for term in terms where haystack.localizedCaseInsensitiveContains(term) {
                matches += 1
            }
            if terms.isEmpty || matches > 0 {
                scored.append((chunk: chunk, matches: matches))
            }
        }
        scored.sort { lhs, rhs in
            lhs.matches == rhs.matches
                ? lhs.chunk.modifiedAt > rhs.chunk.modifiedAt
                : lhs.matches > rhs.matches
        }
        return scored.prefix(Self.candidateLimit).map(\.chunk)
    }

    private func prepareSemanticModelIfAvailable() {
        if semanticModel != nil { return }
        guard let model = NLContextualEmbedding(language: .english) else { return }
        guard model.hasAvailableAssets else {
            guard !didRequestSemanticAssets else { return }
            didRequestSemanticAssets = true
            model.requestAssets { _, _ in }
            return
        }
        do {
            try model.load()
            semanticModel = model
        } catch {
            semanticModel = nil
        }
    }

    private func semanticVector(for text: String) -> [Float]? {
        guard let semanticModel else { return nil }
        do {
            let result = try semanticModel.embeddingResult(
                for: String(text.prefix(2_000)),
                language: nil
            )
            var pooled = [Double](repeating: 0, count: semanticModel.dimension)
            var count = 0
            result.enumerateTokenVectors(
                in: result.string.startIndex..<result.string.endIndex
            ) { vector, _ in
                guard vector.count == pooled.count else { return true }
                for index in pooled.indices { pooled[index] += vector[index] }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            let magnitude = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
            guard magnitude > 0 else { return nil }
            return pooled.map { Float($0 / magnitude) }
        } catch {
            return nil
        }
    }

    private func semanticCandidates(query: String) -> [(String, Int)] {
        guard !semanticVectors.isEmpty,
              let queryVector = semanticVector(for: query) else {
            return []
        }
        return semanticVectors.compactMap { id, vector -> (String, Float)? in
            guard vector.count == queryVector.count else { return nil }
            var score: Float = 0
            for index in vector.indices { score += vector[index] * queryVector[index] }
            return (id, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(Self.candidateLimit)
        .enumerated().map { ($0.element.0, $0.offset + 1) }
    }

    private func store(vector: [Float], chunkID: String) throws {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO context_vectors(chunk_id, vector) VALUES(?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, chunkID, -1, Self.transient)
        _ = vector.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        _ = sqlite3_step(statement)
    }

    private func loadStoredVectors() {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT chunk_id, vector FROM context_vectors",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idValue = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
            let buffer = bytes.bindMemory(to: Float.self, capacity: count)
            semanticVectors[String(cString: idValue)] = Array(
                UnsafeBufferPointer(start: buffer, count: count)
            )
        }
    }

    private func execute(
        _ sql: String,
        bindings: [String],
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        _ = sqlite3_step(statement)
    }

    private nonisolated static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private nonisolated static func userVersion(database: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA user_version",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private nonisolated static func queryTerms(_ query: String) -> [String] {
        var seen: Set<String> = []
        return query.split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "/" && $0 != "@" }
            .map { String($0).lowercased() }
            .filter { $0.count >= 2 && seen.insert($0).inserted }
            .prefix(24).map { $0 }
    }

    private nonisolated static func chunks(for document: ContextDocument) -> [Chunk] {
        let blocks = document.markdown.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return [] }
        var result: [Chunk] = []
        var current: [String] = []
        let title = document.customDisplayName
            ?? document.appSessionMetadata?.applicationName
            ?? document.id

        func appendCurrent() {
            guard !current.isEmpty else { return }
            let content = current.joined(separator: " ")
            let ordinal = result.count
            result.append(Chunk(
                id: "\(document.id):\(ordinal):\(String(hash(content).prefix(12)))",
                documentID: document.id,
                title: title,
                content: content,
                modifiedAt: document.modifiedAt,
                applicationName: document.appSessionMetadata?.applicationName,
                bundleIdentifier: document.appSessionMetadata?.bundleIdentifier,
                ordinal: ordinal
            ))
        }

        for block in blocks {
            var offset = 0
            if !current.isEmpty,
               current.count + block.count > maximumChunkWords {
                appendCurrent()
                current = Array(current.suffix(overlapWords))
            }
            while offset < block.count {
                let capacity = maximumChunkWords - current.count
                let end = min(block.count, offset + capacity)
                current.append(contentsOf: block[offset..<end])
                offset = end
                if current.count == maximumChunkWords, offset < block.count {
                    appendCurrent()
                    current = Array(current.suffix(overlapWords))
                }
            }
        }
        if result.last?.content != current.joined(separator: " ") {
            appendCurrent()
        }
        return result
    }

    private nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
