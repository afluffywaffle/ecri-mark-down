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
    @State private var showOpenPanel = false
    @State private var showSavePanel = false
    @State private var showSettings = false
    #if !os(macOS)
    @State private var showTabSwitcher = false
    // Inline rename of the toolbar title (the iOS analogue of double-clicking a
    // macOS tab). renameDoc pins the rename to the doc it started on so switching
    // tabs mid-rename can't commit to the wrong document.
    @State private var renamingTitle = false
    @State private var renameText = ""
    @State private var renameDoc: Document?
    @FocusState private var titleFieldFocused: Bool
    #endif
    @State private var exportDoc = MarkdownFile()
    @State private var closeCandidate: Document?
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @State private var caret = CaretPosition()
    @State private var topVisibleIndex = 0
    @State private var wordCount = 0
    @State private var wordCountWork: DispatchWorkItem?
    @State private var findModel = FindModel.shared
    @State private var outlineModel = OutlineModel.shared
    @Environment(\.controlActiveState) private var controlActiveState
    /// Retained per-window so the red close button prompts before discarding edits
    /// (the tab-close and quit paths already guard; the window close did not).
    @State private var closeGuard = WindowCloseGuard()
    #endif

    private var mode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .source }
    private var modeBinding: Binding<ViewMode> {
        Binding(get: { ViewMode(rawValue: viewModeRaw) ?? .source },
                set: { viewModeRaw = $0.rawValue })
    }

    var body: some View {
        root
            .focusedSceneValue(\.editorStore, store)
        #if !os(macOS)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTabSwitcher) {
            TabSwitcherView(store: store, onClose: requestClose)
        }
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

    /// The platform root. macOS: tab strip + editor stack, framed. iOS: a
    /// NavigationStack so the toolbar (open/save/tabs/…) actually renders — a plain
    /// window has no navigation bar, so `.navigationBarLeading` / `.principal` /
    /// `.primaryAction` toolbar placements are silently dropped without one.
    #if os(macOS)
    private var root: some View {
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
        .background(WindowAccessor { window in
            guard let window else { return }
            closeGuard.store = store
            if window.delegate !== closeGuard { window.delegate = closeGuard }
        })
        .onAppear { setUpWindow(); recomputeWordCount() }
        // Word count recomputes immediately on document switch, and (debounced) from the
        // editor's onEdit callback while typing — NOT via an onChange on content, which
        // would re-evaluate the whole view on every keystroke.
        .onChange(of: store.selectedID) { _, _ in recomputeWordCount() }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { WindowRouter.shared.setActive(store) }
        }
    }
    #else
    private var root: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if EditorSettings.shared.formattingToolsEnabled {
                    FormattingBar()
                    Divider()
                }
                editorRow
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }
    #endif

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
            if let doc = store.selectedDocument { editorArea(for: doc) } else { Color.clear }
        }
        #else
        // Safari-style tab paging: swipe left/right to switch between open tabs.
        // No tab strip — the toolbar title + tabs button show and switch tabs.
        TabView(selection: selectedTabBinding) {
            ForEach(store.documents) { doc in
                editorArea(for: doc)
                    .tag(doc.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }

    /// The editor for one document. On iOS this is one page of the tab pager;
    /// on macOS it's the single editor under the tab strip.
    @ViewBuilder
    func editorArea(for doc: Document) -> some View {
        #if os(macOS)
        ZStack {
            MarkdownEditorView(document: doc, mode: mode, caret: $caret,
                               topVisibleIndex: $topVisibleIndex,
                               onEdit: {
                if !doc.isModified { doc.isModified = true }
                store.scheduleAutosave(doc)
                scheduleWordCount()
            })
            .id(doc.id)

            if doc.fileURL == nil, doc.content.isEmpty, !RecentsStore.shared.items.isEmpty {
                RecentsWelcomeView(store: store, onOpen: { openAction() })
            }
        }
        #else
        EditorPageView(doc: doc, store: store, mode: mode,
                       isActive: store.selectedID == doc.id,
                       onOpen: { openAction() })
        .id(doc.id)
        #endif
    }

    /// Drives the iOS page switcher (and macOS selection) from the selected doc id.
    private var selectedTabBinding: Binding<UUID> {
        Binding(
            get: { store.selectedID ?? store.documents.first?.id ?? UUID() },
            set: { store.selectedID = $0 }
        )
    }

    func openAction() {
        #if os(macOS)
        WindowRouter.shared.openViaPanel()
        #else
        showOpenPanel = true
        #endif
    }

    /// Resolve the selected document (used by macOS close-guard helpers and the
    /// toolbar title on iOS).
    private var currentDoc: Document? { store.selectedDocument }

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

    #if os(macOS)
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
    #endif

    #if os(macOS)
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
    #endif

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button {
                modeBinding.wrappedValue = mode.next
            } label: {
                Label("Cycle View", systemImage: mode.symbol)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Cycle View: Source → Split → Preview (⌘⇧P)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                outlineModel.toggle()
            } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("Toggle Outline — filter/jump by heading (⌘⇧O)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                EditorSettings.shared.formattingToolsEnabled.toggle()
            } label: {
                Label("Authoring Mode",
                      systemImage: EditorSettings.shared.formattingToolsEnabled ? "pencil.circle.fill" : "pencil.circle")
            }
            .help(EditorSettings.shared.formattingToolsEnabled
                  ? "Authoring mode on — click for reader mode"
                  : "Reader mode — click to enable authoring")
        }

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
        #else
        // iOS/iPadOS has no menu bar, so Open/Save must be reachable on the toolbar.
        // Use separate ToolbarItems — a crowded ToolbarItemGroup silently drops
        // items on iPhone.
        ToolbarItem(placement: .navigationBarLeading) {
            Button { openAction() } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open File")
        }

        // The current document's title. Tap to rename (double-click on macOS);
        // tab switching lives on the Tabs button, not the title.
        ToolbarItem(placement: .principal) {
            if renamingTitle {
                TextField("Title", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .focused($titleFieldFocused)
                    .onSubmit(commitTitleRename)
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused && renamingTitle { commitTitleRename() }
                    }
            } else {
                Button(action: beginTitleRename) {
                    Text(store.selectedDocument?.displayTitle ?? "Untitled")
                        .font(.headline)
                        .lineLimit(1)
                }
                .help("Rename")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button { saveAction() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!(store.selectedDocument?.isModified ?? false))
            .help("Save")
        }

        // The macOS Editor menu's Source / Split / Preview, in a menu — direct
        // selection with the active mode checkmarked (iOS has no menu bar).
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ViewMode.allCases) { viewMode in
                    Button {
                        viewModeRaw = viewMode.rawValue
                    } label: {
                        if mode == viewMode {
                            Label(viewMode.label, systemImage: "checkmark")
                        } else {
                            Text(viewMode.label)
                        }
                    }
                }
            } label: {
                Label("View", systemImage: mode.symbol)
            }
            .help("View: Source, Split, Preview")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { showTabSwitcher = true } label: {
                Label("Tabs", systemImage: "square.on.square")
            }
            .help("Open Tabs")
        }

        // Authoring toggle + Settings fold into a menu so the trailing group stays
        // small enough that nothing overflows off the screen.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    EditorSettings.shared.formattingToolsEnabled.toggle()
                } label: {
                    Label(EditorSettings.shared.formattingToolsEnabled
                          ? "Hide Formatting Toolbar" : "Show Formatting Toolbar",
                          systemImage: "pencil.circle")
                }
                Divider()
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More options")
        }
        #endif
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

    #if !os(macOS)
    private func beginTitleRename() {
        guard let doc = store.selectedDocument else { return }
        renameText = doc.title
        renameDoc = doc
        renamingTitle = true
        titleFieldFocused = true
    }

    private func commitTitleRename() {
        guard renamingTitle else { return }
        renamingTitle = false
        titleFieldFocused = false
        guard let doc = renameDoc else { return }
        renameDoc = nil
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { doc.title = trimmed }
    }
    #endif
}

#if !os(macOS)
/// One page in the iOS tab pager. Owns its own caret/scroll state so background
/// pages don't fight the visible one over a shared status-bar binding.
private struct EditorPageView: View {
    var doc: Document
    var store: EditorStore
    var mode: ViewMode
    var isActive: Bool
    var onOpen: () -> Void

    @State private var caret = CaretPosition()
    @State private var topVisibleIndex = 0
    @State private var wordCount = 0
    @State private var wordCountWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            MarkdownEditorView(document: doc, mode: mode, caret: $caret,
                               topVisibleIndex: $topVisibleIndex,
                               isActive: isActive,
                               onEdit: {
                // Guard the flag: setting it every keystroke re-notifies observers
                // (status bar, tabs) even when it's already true.
                if !doc.isModified { doc.isModified = true }
                store.scheduleAutosave(doc)
                scheduleWordCount()
            })
        }
        .overlay(alignment: .bottom) {
            if EditorSettings.shared.showStatusBar {
                EditorStatusBar(doc: doc, caret: caret, wordCount: wordCount)
            }
        }
        .onChange(of: store.selectedID) { _, _ in
            if store.selectedID == doc.id { recomputeWordCount() }
        }

        // Welcome / recents on a fresh empty tab. Disappears once you type.
        if doc.fileURL == nil, doc.content.isEmpty, !RecentsStore.shared.items.isEmpty {
            RecentsWelcomeView(store: store, onOpen: onOpen)
        }
    }

    private func recomputeWordCount() {
        wordCountWork?.cancel()
        wordCount = doc.wordCount
    }

    /// Recompute the word count 0.4s after the last keystroke, so rapid typing on a
    /// large document doesn't split the whole string on every character.
    private func scheduleWordCount() {
        wordCountWork?.cancel()
        let work = DispatchWorkItem { [weak doc] in
            guard let doc else { return }
            wordCount = doc.wordCount
        }
        wordCountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// Slim status bar shown at the bottom of each iOS editor page.
private struct EditorStatusBar: View {
    var doc: Document
    var caret: CaretPosition
    var wordCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Text("\(wordCount) words")
            Spacer()
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
#endif

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

// MARK: - Window close guard (macOS)

#if os(macOS)
/// Intercepts the window's red close button so unsaved documents get a
/// Save / Don't Save / Cancel prompt before the window (and its `EditorStore`)
/// is destroyed. Tab-close (`requestClose`) and quit (`applicationShouldTerminate`)
/// already guard; closing the window itself was the unguarded path.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var store: EditorStore?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let store, store.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = store.documents.count == 1
            ? "Save changes to “\(store.selectedDocument?.title ?? "Untitled")” before closing?"
            : "You have documents with unsaved changes in this window."
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for doc in store.documents where doc.isModified {
                store.selectedID = doc.id
                store.saveSelected()
                // Still dirty → the user cancelled a Save As panel; keep the window open.
                if doc.isModified { return false }
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

/// Grabs the hosting `NSWindow` out of a SwiftUI background view so `ContentView`
/// can install a close guard. Setting the window's delegate is safe — SwiftUI
/// WindowGroup doesn't use the delegate slot for its own close handling.
struct WindowAccessor: NSViewRepresentable {
    var windowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { windowChanged(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { windowChanged(nsView.window) }
    }
}
#endif

#Preview {
    ContentView()
}
