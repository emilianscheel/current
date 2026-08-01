import AppKit
import CurrentCore
import ImageIO
import Observation
import SwiftUI

@MainActor
private final class ContextSearchWindow: NSWindow {
    var presentSearch: (() -> Void)?
    var presentNewDocument: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            presentSearch?()
            return true
        }
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "n" {
            presentNewDocument?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ContextWindowController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let store: ContextStore
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?
    private var viewModel: ContextViewModel?
    private weak var newDocumentMenuItem: NSMenuItem?
    private weak var newDocumentMenuSeparator: NSMenuItem?

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
            let window = ContextSearchWindow(contentViewController: controller)
            window.presentSearch = { [weak viewModel] in
                viewModel?.presentSearch()
            }
            window.presentNewDocument = { [weak viewModel] in
                viewModel?.presentNewDocument()
            }
            window.title = "Context"
            window.styleMask = [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
            ]
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .none
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
        installNewDocumentMenuItem()
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
        removeNewDocumentMenuItem()
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        installNewDocumentMenuItem()
    }

    @objc private func newContextDocument(_ sender: Any?) {
        window?.makeKeyAndOrderFront(sender)
        viewModel?.presentNewDocument()
    }

    private func installNewDocumentMenuItem() {
        guard newDocumentMenuItem == nil,
              let fileMenu = NSApp.mainMenu?.items.first(where: {
                  $0.title == "File" || $0.submenu?.title == "File"
              })?.submenu else { return }
        let item = NSMenuItem(
            title: "New Context Document",
            action: #selector(newContextDocument(_:)),
            keyEquivalent: "n"
        )
        item.keyEquivalentModifierMask = .command
        item.target = self
        let separator = NSMenuItem.separator()
        fileMenu.insertItem(separator, at: 0)
        fileMenu.insertItem(item, at: 0)
        newDocumentMenuItem = item
        newDocumentMenuSeparator = separator
    }

    private func removeNewDocumentMenuItem() {
        if let item = newDocumentMenuItem {
            item.menu?.removeItem(item)
        }
        if let separator = newDocumentMenuSeparator {
            separator.menu?.removeItem(separator)
        }
    }
}

private final class CachedSidebarIcon {
    let image: NSImage?

    init(image: NSImage?) {
        self.image = image
    }
}

@MainActor
private final class ContextSidebarIconCache {
    private let images = NSCache<NSString, CachedSidebarIcon>()

    init() {
        images.countLimit = 64
        images.totalCostLimit = 4 * 1_024 * 1_024
    }

    func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) {
            return cached.image
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        let image = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap {
                CGImageSourceCreateThumbnailAtIndex(
                    $0,
                    0,
                    options as CFDictionary
                )
            }
            .map {
                NSImage(
                    cgImage: $0,
                    size: NSSize(width: 28, height: 28)
                )
            }
        images.setObject(
            CachedSidebarIcon(image: image),
            forKey: key,
            cost: 64 * 64 * 4
        )
        return image
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
    var isSearchPresented = false
    var isNewDocumentPresented = false
    var newDocumentTitle = ""
    private(set) var editorFocusRequest = UUID()
    private(set) var selectedDocumentID: String?
    var richText = AttributedString()
    var selection = AttributedTextSelection()
    private(set) var saveStatus: SaveStatus = .saved

    private var lastSavedMarkdown = ""
    private var autosaveTask: Task<Void, Never>?
    private var formattingIdentity = 10_000
    private var isDirty = false
    private var baselineRichText = AttributedString()
    @ObservationIgnored private let sidebarPresentationCache =
        ContextSidebarPresentationCache()
    @ObservationIgnored private let sidebarIconCache = ContextSidebarIconCache()

    init(store: ContextStore, repository: ContextRepository) {
        self.store = store
        self.repository = repository
        selectedDocumentID = store.documents.first?.id
        loadSelection()
    }

    var sidebarItems: [ContextSidebarItem] {
        sidebarPresentationCache.items(in: store, matching: searchText)
    }

    var selectedDocument: ContextDocument? {
        guard let selectedDocumentID else { return nil }
        return store.document(id: selectedDocumentID)
    }

    func presentSearch() {
        if isSearchPresented {
            isSearchPresented = false
            Task { [weak self] in
                await Task.yield()
                self?.isSearchPresented = true
            }
        } else {
            isSearchPresented = true
        }
    }

    func presentNewDocument() {
        newDocumentTitle = ""
        isNewDocumentPresented = true
    }

    func createManualDocument() {
        isNewDocumentPresented = false
        do {
            let document = try store.createManualDocument(
                title: newDocumentTitle
            )
            selectedDocumentID = document.id
            searchText = ""
            loadSelection()
            Task { [weak self] in
                await Task.yield()
                self?.editorFocusRequest = UUID()
            }
        } catch {
            show(error)
        }
    }

    func appIcon(relativePath: String?) -> NSImage? {
        guard let relativePath else { return nil }
        return sidebarIconCache.image(
            at: store.directory.appendingPathComponent(relativePath)
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
    @FocusState private var editorFocused: Bool
    @State private var showingLinkEditor = false
    @State private var linkURL = ""

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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.presentNewDocument()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("New Context Document")
            }
        }
        .searchable(
            text: $model.searchText,
            isPresented: $model.isSearchPresented,
            placement: .toolbar,
            prompt: "Search context"
        )
        .alert(
            "New Context Document",
            isPresented: $model.isNewDocumentPresented
        ) {
            TextField("Title", text: $model.newDocumentTitle)
            Button("Cancel", role: .cancel) {
                model.isNewDocumentPresented = false
            }
            Button("Create") {
                model.createManualDocument()
            }
            .disabled(!isValidNewDocumentTitle)
        } message: {
            Text("Choose a title for the new Markdown context document.")
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
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                model.refreshLiveDocumentIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        ContextSidebarView(model: model)
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
                    .focused($editorFocused)
                    .onChange(of: model.richText) { _, _ in model.textChanged() }
                    .onChange(of: model.editorFocusRequest) { _, _ in
                        editorFocused = true
                    }
            }
        } else {
            Color.clear
        }
    }

    private var isValidNewDocumentTitle: Bool {
        let title = model.newDocumentTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 120
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

private struct ContextSidebarView: View {
    @Bindable var model: ContextViewModel
    @State private var pendingDeletionID: String?
    @State private var pendingRenameID: String?
    @State private var renameText = ""

    var body: some View {
        List(
            selection: Binding(
                get: { model.selectedDocumentID },
                set: { if let documentID = $0 { model.select(documentID) } }
            )
        ) {
            ForEach(model.sidebarItems) { item in
                contextRow(item)
                    .tag(item.id)
                    .listRowInsets(
                        EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10)
                    )
                    .contextMenu {
                        Button("Copy Contents", systemImage: "doc.on.doc") {
                            model.copyMarkdown(documentID: item.id)
                        }
                        if !item.isProtected {
                            Button("Rename…", systemImage: "pencil") {
                                pendingRenameID = item.id
                                renameText = item.title
                            }
                            Divider()
                            Button(
                                "Move to Trash",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                pendingDeletionID = item.id
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .tint(Color.gray.opacity(0.18))
        .confirmationDialog(
            "Move this context document to Trash?",
            isPresented: Binding(
                get: { pendingDeletionID != nil },
                set: { if !$0 { pendingDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingDeletionID {
                    model.moveToTrash(documentID: pendingDeletionID)
                }
                pendingDeletionID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletionID = nil }
        }
        .alert(
            "Rename Context Document",
            isPresented: Binding(
                get: { pendingRenameID != nil },
                set: { if !$0 { pendingRenameID = nil } }
            )
        ) {
            TextField("Display name", text: $renameText)
            Button("Cancel", role: .cancel) {
                pendingRenameID = nil
            }
            Button("Rename") {
                if let pendingRenameID {
                    model.rename(
                        documentID: pendingRenameID,
                        displayName: renameText
                    )
                }
                pendingRenameID = nil
            }
        } message: {
            Text("This changes the sidebar name without renaming the Markdown file.")
        }
    }

    private func contextRow(_ item: ContextSidebarItem) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = model.appIcon(relativePath: item.iconRelativePath) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: item.symbolName)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
    }
}
