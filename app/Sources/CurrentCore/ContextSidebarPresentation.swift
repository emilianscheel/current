import Foundation

public struct ContextSidebarItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let iconRelativePath: String?
    public let isProtected: Bool
}

@MainActor
public final class ContextSidebarPresentationCache {
    private enum KindSignature: Equatable {
        case dailyDictation(date: Date)
        case appSession(
            applicationName: String,
            startedAt: Date,
            endedAt: Date?,
            iconRelativePath: String?
        )
        case manual(title: String, role: ManualContextDocumentRole)
    }

    private struct Signature: Equatable {
        let modifiedAt: Date
        let customDisplayName: String?
        let kind: KindSignature

        init(document: ContextDocument) {
            modifiedAt = document.modifiedAt
            customDisplayName = document.customDisplayName
            kind = switch document.kind {
            case .dailyDictation:
                .dailyDictation(date: document.date)
            case .appSession(let metadata):
                .appSession(
                    applicationName: metadata.applicationName,
                    startedAt: metadata.startedAt,
                    endedAt: metadata.endedAt,
                    iconRelativePath: metadata.iconRelativePath
                )
            case .manual(let metadata):
                .manual(title: metadata.title, role: metadata.role)
            }
        }
    }

    private struct Entry {
        let signature: Signature
        let item: ContextSidebarItem
    }

    private var entries: [String: Entry] = [:]
    private var lastStoreRevision: UInt64?
    private var lastQuery: String?
    private var lastItems: [ContextSidebarItem] = []
    private(set) var generationCount = 0

    public init() {}

    public func items(
        in store: ContextStore,
        matching query: String
    ) -> [ContextSidebarItem] {
        guard lastStoreRevision != store.revision || lastQuery != query else {
            return lastItems
        }

        let currentIDs = Set(store.documents.map(\.id))
        entries = entries.filter { currentIDs.contains($0.key) }
        lastItems = store.filteredDocuments(matching: query).map { document in
            let signature = Signature(document: document)
            if let entry = entries[document.id], entry.signature == signature {
                return entry.item
            }

            let item = makeItem(for: document, store: store)
            entries[document.id] = Entry(signature: signature, item: item)
            generationCount += 1
            return item
        }
        lastStoreRevision = store.revision
        lastQuery = query
        return lastItems
    }

    private func makeItem(
        for document: ContextDocument,
        store: ContextStore
    ) -> ContextSidebarItem {
        let title: String
        if let alias = document.customDisplayName {
            title = alias
        } else {
            title = switch document.kind {
            case .dailyDictation:
                store.displayTitle(for: document.date)
            case .appSession(let metadata):
                metadata.applicationName
            case .manual(let metadata):
                metadata.title
            }
        }

        let wordCount = document.wordCount
        let subtitle: String
        let symbolName: String
        let iconRelativePath: String?
        switch document.kind {
        case .dailyDictation:
            subtitle = "\(wordCount) words"
            symbolName = "calendar"
            iconRelativePath = nil
        case .appSession(let metadata):
            let started = metadata.startedAt.formatted(
                date: .omitted,
                time: .shortened
            )
            if let endedAt = metadata.endedAt {
                subtitle = "\(started)–\(endedAt.formatted(date: .omitted, time: .shortened)) · \(wordCount) words"
            } else {
                subtitle = "\(started) · Active · \(wordCount) words"
            }
            symbolName = "calendar"
            iconRelativePath = metadata.iconRelativePath
        case .manual(let metadata):
            subtitle = "\(wordCount) words"
            symbolName = switch metadata.role {
            case .aboutMe: "person.crop.circle"
            case .instructions: "checklist"
            case .custom: "doc.text"
            }
            iconRelativePath = nil
        }

        return ContextSidebarItem(
            id: document.id,
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            iconRelativePath: iconRelativePath,
            isProtected: document.isProtected
        )
    }
}
