import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

private let epubType: UTType = UTType(filenameExtension: "epub")
    ?? UTType(importedAs: "org.idpf.epub-container")
private let docxType: UTType = UTType(filenameExtension: "docx")
    ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")

struct ContentView: View {
    var pending: PendingOpen? = nil

    @State private var store = EditorStore()
    @AppStorage("viewMode") private var viewModeRaw = ViewMode.source.rawValue
    @State private var caret = CaretPosition()
    @State private var topVisibleIndex = 0
    @State private var showOpenPanel = false
    @State private var showSavePanel = false
    @State private var showSettings = false
    @State private var exportDoc = MarkdownFile()
    @State private var closeCandidate: Document?
    @State private var wordCount = 0
    @State private var wordCountWork: DispatchWorkItem?
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @State private var findModel = FindModel.shared
    @State private var outlineModel = OutlineModel.shared
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var mode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .source }
    private var modeBinding: Binding<ViewMode> {
        Binding(get: { ViewMode(rawValue: viewModeRaw) ?? .source },
                set: { viewModeRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store, onClose: requestClose,
                       onMove: { WindowRouter.shared.moveToNewWindow($0, from: store) })
            Divider()
            if EditorSettings.shared.formattingToolsEnabled {
                FormattingBar()
                Divider()
            }
            editorRow
            statusBar
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar { toolbar }
        .focusedSceneValue(\.editorStore, store)
        .onAppear { setUpWindow(); recomputeWordCount() }
        // Word count recomputes immediately on document switch, and (debounced) from the
        // editor's onEdit callback while typing — NOT via an onChange on content, which
        // would re-evaluate the whole view on every keystroke.
        .onChange(of: store.selectedID) { _, _ in recomputeWordCount() }
        #if os(macOS)
        .onChange(of: controlActiveState) { _, state in
            if state == .key { WindowRouter.shared.setActive(store) }
        }
        #endif
        #if !os(macOS)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog("Save changes before closing?",
                            isPresented: Binding(get: { closeCandidate != nil },
                                                 set: { if !$0 { closeCandidate = nil } }),
                            presenting: closeCandidate) { doc in
            Button("Discard Changes", role: .destructive) { store.close(doc); closeCandidate = nil }
            Button("Cancel", role: .cancel) { closeCandidate = nil }
        } message: { doc in
            Text("“\(doc.title)” has unsaved changes.")
        }
        #endif
        .fileImporter(
            isPresented: $showOpenPanel,
            allowedContentTypes: [.plainText, .rtf, epubType, docxType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            store.open(url: url)
        }
        .fileExporter(
            isPresented: $showSavePanel,
            document: exportDoc,
            contentType: .plainText,
            defaultFilename: defaultExportFilename
        ) { result in
            guard case .success(let url) = result else { return }
            store.selectedDocument?.fileURL = url
            store.selectedDocument?.title = url.lastPathComponent
            store.selectedDocument?.isModified = false
        }
    }

    var defaultExportFilename: String {
        guard let doc = store.selectedDocument else { return "Untitled.md" }
        let base = doc.title
        let ext = doc.preferredSaveExtension
        // Strip any existing known extension before appending the preferred one
        let knownExtensions = ["md", "txt", "rtf", "rtfd", "epub", "docx"]
        let currentExt = (base as NSString).pathExtension.lowercased()
        if knownExtensions.contains(currentExt) {
            return (base as NSString).deletingPathExtension + "." + ext
        }
        return base.isEmpty ? "Untitled.\(ext)" : base + "." + ext
    }

    @ViewBuilder
    var editorRow: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            if findModel.isOpen {
                FindSidebar(text: store.selectedDocument?.content ?? "")
                Divider()
            }
            if outlineModel.isOpen {
                OutlineSidebar(text: store.selectedDocument?.content ?? "")
                Divider()
            }
            editorArea
        }
        #else
        editorArea
        #endif
    }

    @ViewBuilder
    var editorArea: some View {
        if let doc = store.selectedDocument {
            ZStack {
                MarkdownEditorView(document: doc, mode: mode, caret: $caret,
                                   topVisibleIndex: $topVisibleIndex, onEdit: {
                    // Guard the flag: setting it every keystroke re-notifies observers
                    // (tab bar, status bar) even when it's already true.
                    if !doc.isModified { doc.isModified = true }
                    store.scheduleAutosave(doc)
                    scheduleWordCount()
                })
                .id(doc.id)

                // Welcome / recents on a fresh empty tab. Disappears once you type.
                if doc.fileURL == nil, doc.content.isEmpty, !RecentsStore.shared.items.isEmpty {
                    RecentsWelcomeView(store: store, onOpen: { openAction() })
                }
            }
        } else {
            Color.clear
        }
    }

    func openAction() {
        #if os(macOS)
        WindowRouter.shared.openViaPanel()
        #else
        showOpenPanel = true
        #endif
    }

    private func setUpWindow() {
        WindowRouter.shared.register(store)
        WindowRouter.shared.openWindow = { po in openWindow(value: po) }
        // Deliver any Finder-opens that arrived before this window wired up.
        WindowRouter.shared.flushPendingOpens()
        guard let pending else { return }

        let url = pending.bookmark.flatMap(resolveBookmark)

        if let content = pending.content {
            // A tab torn off into this window — keep its content, file, and dirty state.
            let doc = Document(title: pending.title ?? "Untitled", content: content, fileURL: url)
            doc.isModified = pending.isModified ?? false
            store.adopt(doc)
        } else if let url {
            store.open(url: url)
        } else if pending.bookmark != nil {
            // This window was created to show a file, but its bookmark no longer
            // resolves (stale restoration data, file moved). Say so rather than
            // silently presenting a blank untitled window.
            EditorStore.presentOpenFailure(nil)
        }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func saveAction() {
        #if os(macOS)
        store.saveSelected()
        #else
        saveCurrentDoc()
        #endif
    }

    /// Close a tab, guarding against losing unsaved changes.
    func requestClose(_ doc: Document) {
        guard doc.isModified else { store.close(doc); return }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.title)” before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.selectedID = doc.id
            store.saveSelected()
            if !doc.isModified { store.close(doc) }   // only close if the save succeeded
        case .alertSecondButtonReturn:
            store.close(doc)
        default:
            break
        }
        #else
        closeCandidate = doc
        #endif
    }

    @ViewBuilder
    var statusBar: some View {
        if EditorSettings.shared.showStatusBar, let doc = store.selectedDocument {
            Divider()
            HStack(spacing: 16) {
                Text("Ln \(caret.line), Col \(caret.column)")
                Text("\(wordCount) words")
                Spacer()
                Text(saveStatusText(for: doc))
                Text(doc.fileTypeLabel)
                    .fontWeight(.medium)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(.bar)
        }
    }

    /// Count words in the selected document now (used on load / document switch).
    private func recomputeWordCount() {
        wordCountWork?.cancel()
        wordCount = store.selectedDocument?.wordCount ?? 0
    }

    /// Recompute the word count 0.4s after the last keystroke, so rapid typing on a
    /// large document doesn't split the whole string on every character.
    private func scheduleWordCount() {
        wordCountWork?.cancel()
        guard let doc = store.selectedDocument else { return }
        let work = DispatchWorkItem { [weak doc] in
            guard let doc else { return }
            wordCount = doc.wordCount
        }
        wordCountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveStatusText(for doc: Document) -> String {
        if !doc.isModified { return "Saved" }
        if EditorSettings.shared.autosave, doc.fileURL != nil { return "Saving…" }
        return "Edited"
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            #if !os(macOS)
            // iOS/iPadOS has no menu bar, so keep Open/Save reachable on the toolbar.
            Button { openAction() } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open File")

            Button { saveAction() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!(store.selectedDocument?.isModified ?? false))
            .help("Save")
            #endif

            Button {
                modeBinding.wrappedValue = mode.next
            } label: {
                Label("Cycle View", systemImage: mode.symbol)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Cycle View: Source → Split → Preview (⌘⇧P)")

            #if os(macOS)
            Button {
                outlineModel.toggle()
            } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("Toggle Outline — filter/jump by heading (⌘⇧O)")
            #endif

            // Reader ⇄ authoring: surfaced as a button, not buried in Settings.
            Button {
                EditorSettings.shared.formattingToolsEnabled.toggle()
            } label: {
                Label("Authoring Mode",
                      systemImage: EditorSettings.shared.formattingToolsEnabled ? "pencil.circle.fill" : "pencil.circle")
            }
            .help(EditorSettings.shared.formattingToolsEnabled
                  ? "Authoring mode on — click for reader mode"
                  : "Reader mode — click to enable authoring")

            #if os(macOS)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            #else
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            #endif
        }
    }

    func saveCurrentDoc() {
        guard let doc = store.selectedDocument else { return }
        if doc.fileURL != nil {
            store.save(doc)
        } else {
            exportDoc = MarkdownFile(content: doc.content)
            showSavePanel = true
        }
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    var store: EditorStore
    var onClose: (Document) -> Void
    var onMove: (Document) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(store.documents) { doc in
                    TabCell(
                        doc: doc,
                        isSelected: doc.id == store.selectedID,
                        canMove: store.documents.count > 1,
                        onSelect: { store.selectedID = doc.id },
                        onClose: { onClose(doc) },
                        onMove: { onMove(doc) },
                        onReveal: {
                            #if os(macOS)
                            store.revealInFinder(doc)
                            #endif
                        },
                        onRename: { renamed, name in
                            #if os(macOS)
                            store.rename(renamed, to: name)
                            #else
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { renamed.title = trimmed }
                            #endif
                        }
                    )
                }

                Button(action: store.newDocument) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

struct TabCell: View {
    var doc: Document
    var isSelected: Bool
    var canMove: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void
    var onMove: () -> Void = {}
    var onReveal: () -> Void = {}
    var onRename: (Document, String) -> Void = { _, _ in }

    #if os(macOS)
    @State private var isHovered = false
    #endif
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    var showCloseButton: Bool {
        #if os(macOS)
        return isSelected || isHovered
        #else
        return isSelected
        #endif
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                if isEditing {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(maxWidth: 140, alignment: .leading)
                        .focused($fieldFocused)
                        .onSubmit(commitRename)
                        .onChange(of: fieldFocused) { _, focused in
                            if !focused { commitRename() }   // commit when focus leaves
                        }
                        #if os(macOS)
                        .onExitCommand(perform: cancelRename)
                        #endif
                } else {
                    Text(doc.displayTitle)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() })

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(showCloseButton ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isSelected ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contextMenu {
            Button("Rename") { beginRename() }
            Button("Move to New Window") { onMove() }
                .disabled(!canMove)
            #if os(macOS)
            Button("Reveal in Finder") { onReveal() }
                .disabled(doc.fileURL == nil)
            #endif
            Button("Close Tab") { onClose() }
        }
    }

    private func beginRename() {
        editText = doc.title
        isEditing = true
        fieldFocused = true
    }

    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        onRename(doc, editText)
    }

    private func cancelRename() {
        isEditing = false
    }
}

// MARK: - Recents welcome (shown on a fresh empty tab)

struct RecentsWelcomeView: View {
    var store: EditorStore
    var onOpen: () -> Void
    private var recents: [RecentItem] { RecentsStore.shared.items }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Recent")
                    .font(.headline)
                Spacer()
                Button("Open…", action: onOpen)
                    .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(recents.prefix(8)) { item in
                    Button {
                        WindowRouter.shared.openRecent(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(item.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                }
            }

            if recents.count > 1 {
                Button("Clear Recents") { RecentsStore.shared.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

#Preview {
    ContentView()
}
