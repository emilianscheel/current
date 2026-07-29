import AppKit
import CurrentCore
import Observation
import SwiftUI

@MainActor
final class ContextWindowController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let store: ContextStore
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?
    private var viewModel: ContextViewModel?

    init(runtime: AppRuntime, store: ContextStore) {
        self.runtime = runtime
        self.store = store
        super.init()
    }

    func show() {
        store.reload()
        if viewModel == nil {
            viewModel = ContextViewModel(
                store: store,
                repository: runtime.contextRepository
            )
        } else {
            viewModel?.refreshFromDisk()
        }
        if window == nil, let viewModel {
            let controller = NSHostingController(
                rootView: ContextManagementView(model: viewModel)
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Context"
            window.styleMask = [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
            ]
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.setContentSize(NSSize(width: 1_000, height: 680))
            window.minSize = NSSize(width: 760, height: 520)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func append(_ transcription: String, at date: Date) {
        viewModel?.flush()
        do {
            let document = try store.append(transcription, at: date)
            viewModel?.didAppend(documentID: document.id)
        } catch {
            viewModel?.show(error)
        }
    }

    func flush() {
        viewModel?.flush()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.flush()
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }
}

@MainActor
@Observable
final class ContextViewModel {
    enum SaveStatus: Equatable {
        case saved
        case saving
        case failed(String)
    }

    let store: ContextStore
    private let repository: ContextRepository
    var searchText = ""
    private(set) var selectedDocumentID: String?
    var richText = AttributedString()
    var selection = AttributedTextSelection()
    private(set) var saveStatus: SaveStatus = .saved

    private var lastSavedMarkdown = ""
    private var autosaveTask: Task<Void, Never>?
    private var formattingIdentity = 10_000
    private var isDirty = false
    private var baselineRichText = AttributedString()

    init(store: ContextStore, repository: ContextRepository) {
        self.store = store
        self.repository = repository
        selectedDocumentID = store.documents.first?.id
        loadSelection()
    }

    var filteredDocuments: [ContextDocument] {
        store.filteredDocuments(matching: searchText)
    }

    var selectedDocument: ContextDocument? {
        guard let selectedDocumentID else { return nil }
        return store.document(id: selectedDocumentID)
    }

    func displayTitle(for document: ContextDocument) -> String {
        if let alias = document.customDisplayName {
            return alias
        }
        return switch document.kind {
        case .dailyDictation:
            store.displayTitle(for: document.date)
        case .appSession(let metadata):
            metadata.applicationName
        }
    }

    func subtitle(for document: ContextDocument) -> String {
        switch document.kind {
        case .dailyDictation:
            return "\(document.wordCount) words"
        case .appSession(let metadata):
            let started = metadata.startedAt.formatted(
                date: .omitted,
                time: .shortened
            )
            if let endedAt = metadata.endedAt {
                return "\(started)–\(endedAt.formatted(date: .omitted, time: .shortened)) · \(document.wordCount) words"
            }
            return "\(started) · Active · \(document.wordCount) words"
        }
    }

    func appIcon(for document: ContextDocument) -> NSImage? {
        guard case .appSession(let metadata) = document.kind,
              let relativePath = metadata.iconRelativePath else {
            return nil
        }
        return NSImage(
            contentsOf: store.directory.appendingPathComponent(relativePath)
        )
    }

    func select(_ documentID: String) {
        guard selectedDocumentID != documentID else { return }
        flush()
        selectedDocumentID = documentID
        loadSelection()
    }

    func textChanged() {
        guard isDirty || richText != baselineRichText else { return }
        let markdown = MarkdownRichTextCodec.markdown(from: richText)
        guard markdown != lastSavedMarkdown else {
            isDirty = false
            saveStatus = .saved
            return
        }
        isDirty = true
        saveStatus = .saving
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty, let selectedDocumentID else { return }
        let markdown = MarkdownRichTextCodec.markdown(from: richText)
        do {
            try store.save(documentID: selectedDocumentID, markdown: markdown)
            lastSavedMarkdown = markdown
            isDirty = false
            baselineRichText = richText
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
        }
    }

    func refreshFromDisk() {
        flush()
        store.reload()
        if let selectedDocumentID,
           store.document(id: selectedDocumentID) != nil {
            loadSelection()
        } else {
            self.selectedDocumentID = store.documents.first?.id
            loadSelection()
        }
    }

    func refreshLiveDocumentIfNeeded() {
        guard !isDirty,
              let selectedDocument,
              selectedDocument.markdown != lastSavedMarkdown else {
            return
        }
        loadSelection()
    }

    func didAppend(documentID: String) {
        if selectedDocumentID == documentID {
            loadSelection()
        }
    }

    func copyMarkdown(documentID: String) {
        if selectedDocumentID == documentID { flush() }
        guard let markdown = store.document(id: documentID)?.markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func moveToTrash(documentID: String) {
        if selectedDocumentID == documentID { flush() }
        do {
            try store.moveToTrash(documentID: documentID)
            Task {
                await repository.discardSession(documentID: documentID)
            }
            if selectedDocumentID == documentID {
                selectedDocumentID = store.documents.first?.id
                loadSelection()
            }
        } catch {
            show(error)
        }
    }

    func rename(documentID: String, displayName: String) {
        do {
            try store.rename(
                documentID: documentID,
                displayName: displayName
            )
        } catch {
            show(error)
        }
    }

    func show(_ error: Error) {
        saveStatus = .failed(error.localizedDescription)
    }

    func dismissError() {
        if case .failed = saveStatus {
            saveStatus = .saved
        }
    }

    func toggleBold() {
        toggleInline(.stronglyEmphasized)
    }

    func toggleItalic() {
        toggleInline(.emphasized)
    }

    func toggleCode() {
        toggleInline(.code)
    }

    func applyLink(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        richText.transformAttributes(in: &selection) { attributes in
            attributes.link = url
        }
        textChanged()
    }

    func applyBlockStyle(_ style: RichBlockStyle) {
        formattingIdentity += 4
        let identity = formattingIdentity
        if style == .bulleted || style == .numbered {
            let characterSelection: RichTextCharacterSelection
            switch selection.indices(in: richText) {
            case .insertionPoint(let index):
                characterSelection = .insertionPoint(index)
            case .ranges(let ranges):
                characterSelection = .ranges(Array(ranges.ranges))
            }
            RichTextListFormatter.toggle(
                style == .bulleted ? .bulleted : .numbered,
                in: &richText,
                selection: characterSelection,
                identity: identity
            )
            textChanged()
            return
        }

        let intent: PresentationIntent
        switch style {
        case .paragraph:
            intent = PresentationIntent(.paragraph, identity: identity)
        case .heading(let level):
            intent = PresentationIntent(.header(level: level), identity: identity)
        case .quote:
            let quote = PresentationIntent(.blockQuote, identity: identity)
            intent = PresentationIntent(.paragraph, identity: identity + 1, parent: quote)
        case .bulleted, .numbered:
            return
        }
        richText.transformAttributes(in: &selection) { attributes in
            attributes.presentationIntent = intent
        }
        textChanged()
    }

    private func toggleInline(_ intent: InlinePresentationIntent) {
        richText.transformAttributes(in: &selection) { attributes in
            var current = attributes.inlinePresentationIntent ?? []
            if current.contains(intent) { current.remove(intent) }
            else { current.insert(intent) }
            attributes.inlinePresentationIntent = current.isEmpty ? nil : current
        }
        textChanged()
    }

    private func loadSelection() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let selectedDocument else {
            richText = AttributedString()
            baselineRichText = richText
            lastSavedMarkdown = ""
            isDirty = false
            saveStatus = .saved
            return
        }
        lastSavedMarkdown = selectedDocument.markdown
        richText = MarkdownRichTextCodec.attributedString(from: selectedDocument.markdown)
        baselineRichText = richText
        selection = AttributedTextSelection()
        isDirty = false
        saveStatus = .saved
    }
}

enum RichBlockStyle: Equatable {
    case paragraph
    case heading(Int)
    case quote
    case bulleted
    case numbered
}

private struct ContextManagementView: View {
    @Bindable var model: ContextViewModel
    @State private var pendingDeletion: ContextDocument?
    @State private var showingLinkEditor = false
    @State private var linkURL = ""
    @State private var pendingRename: ContextDocument?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 270,
                    max: 340
                )
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                detail
                    .frame(minWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(
            "Context Couldn’t Be Saved",
            isPresented: Binding(
                get: {
                    if case .failed = model.saveStatus { return true }
                    return false
                },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK") { model.dismissError() }
        } message: {
            if case .failed(let message) = model.saveStatus {
                Text(message)
            }
        }
        .confirmationDialog(
            "Move this context document to Trash?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingDeletion {
                    model.moveToTrash(documentID: pendingDeletion.id)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
        .alert(
            "Rename Context Document",
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )
        ) {
            TextField("Display name", text: $renameText)
            Button("Cancel", role: .cancel) {
                pendingRename = nil
            }
            Button("Rename") {
                if let pendingRename {
                    model.rename(
                        documentID: pendingRename.id,
                        displayName: renameText
                    )
                }
                pendingRename = nil
            }
        } message: {
            Text("This changes the sidebar name without renaming the Markdown file.")
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                model.refreshLiveDocumentIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        List(
            selection: Binding(
                get: { model.selectedDocumentID },
                set: { if let documentID = $0 { model.select(documentID) } }
            )
        ) {
            ForEach(model.filteredDocuments) { document in
                contextRow(document)
                    .tag(document.id)
                    .listRowInsets(
                        EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10)
                    )
                    .contextMenu {
                        Button("Copy Contents", systemImage: "doc.on.doc") {
                            model.copyMarkdown(documentID: document.id)
                        }
                        Button("Rename…", systemImage: "pencil") {
                            pendingRename = document
                            renameText = model.displayTitle(for: document)
                        }
                        Divider()
                        Button(
                            "Move to Trash",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            pendingDeletion = document
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Search context"
        )
        .tint(Color.gray.opacity(0.18))
    }

    private func contextRow(_ document: ContextDocument) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = model.appIcon(for: document) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "calendar")
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayTitle(for: document))
                    .lineLimit(1)
                Text(model.subtitle(for: document))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
    }

    @ViewBuilder private var detail: some View {
        if model.selectedDocument != nil {
            VStack(spacing: 0) {
                editorToolbar
                Divider().opacity(0.5)
                TextEditor(text: $model.richText, selection: $model.selection)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .focusEffectDisabled()
                    .onChange(of: model.richText) { _, _ in model.textChanged() }
            }
        } else {
            Color.clear
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Body") { model.applyBlockStyle(.paragraph) }
                Button("Heading 1") { model.applyBlockStyle(.heading(1)) }
                Button("Heading 2") { model.applyBlockStyle(.heading(2)) }
                Button("Heading 3") { model.applyBlockStyle(.heading(3)) }
                Divider()
                Button("Quote") { model.applyBlockStyle(.quote) }
            } label: {
                Text("Style")
            }
            .menuStyle(.borderlessButton)

            Divider().frame(height: 18)

            toolbarButton("Bold", symbol: "bold", shortcut: "b") { model.toggleBold() }
            toolbarButton("Italic", symbol: "italic", shortcut: "i") { model.toggleItalic() }
            toolbarButton("Inline Code", symbol: "chevron.left.forwardslash.chevron.right") { model.toggleCode() }
            toolbarButton("Bulleted List", symbol: "list.bullet") { model.applyBlockStyle(.bulleted) }
            toolbarButton("Numbered List", symbol: "list.number") { model.applyBlockStyle(.numbered) }
            toolbarButton("Link", symbol: "link", shortcut: "k") {
                linkURL = ""
                showingLinkEditor = true
            }
            .popover(isPresented: $showingLinkEditor, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Link").font(.headline)
                    TextField("https://example.com", text: $linkURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                    HStack {
                        Button("Remove") {
                            model.applyLink("")
                            showingLinkEditor = false
                        }
                        Spacer()
                        Button("Apply") {
                            model.applyLink(linkURL)
                            showingLinkEditor = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder private func toolbarButton(
        _ title: String,
        symbol: String,
        shortcut: Character? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(title)
        if let shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            button
        }
    }

}
