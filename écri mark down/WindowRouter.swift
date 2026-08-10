import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Value used to open a window. A nil payload is a blank session; a `bookmark`
/// opens a file; `content` carries an in-memory document (e.g. a tab torn off to
/// its own window, preserving unsaved edits).
struct PendingOpen: Codable, Hashable {
    var bookmark: Data?
    var title: String?
    var content: String?
    var isModified: Bool?
}

/// Exposes the focused window's document store to menu commands.
struct EditorStoreKey: FocusedValueKey { typealias Value = EditorStore }
extension FocusedValues {
    var editorStore: EditorStore? {
        get { self[EditorStoreKey.self] }
        set { self[EditorStoreKey.self] = newValue }
    }
}

/// Coordinates opening files across independent windows. Each window has its own
/// `EditorStore`; this routes opens to a new window or the active window's tabs
/// depending on the user's preference, and tracks all live stores for the quit guard.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Captured from a SwiftUI view's environment so non-view code can open windows.
    var openWindow: ((PendingOpen) -> Void)?
    weak var activeStore: EditorStore?
    let stores = NSHashTable<EditorStore>.weakObjects()

    /// Files requested (e.g. via Finder-open at cold launch) before any window
    /// has wired up the router. Flushed into the first window once it registers.
    private var pendingOpens: [URL] = []

    /// True once any window has finished appearing. Before that, both direct
    /// store opens and `openWindow(value:)` are unreliable — SwiftUI can drop
    /// openWindow calls made before the scene phase is active, which is how a
    /// cold Finder-open could end up showing only a blank untitled window.
    private var windowHasRegistered = false

    func register(_ store: EditorStore) {
        stores.add(store)
        activeStore = store
        windowHasRegistered = true
    }

    /// Called once a window has finished wiring up (`openWindow` set). Opens any
    /// files that arrived before the router was ready into the now-active window.
    func flushPendingOpens() {
        guard !pendingOpens.isEmpty, let store = activeStore else { return }
        let urls = pendingOpens
        pendingOpens.removeAll()
        // Open into the existing (initially blank) window so a cold Finder-open
        // shows the file here instead of dropping it and leaving a blank window.
        urls.forEach { store.open(url: $0) }
    }

    func setActive(_ store: EditorStore) { activeStore = store }

    /// Open a file honoring the "new tab vs new window" preference.
    func openFile(url: URL) {
        // No window has appeared yet (Finder-open during cold launch). Even if
        // `openWindow` happens to be set, calling it this early can be silently
        // dropped by SwiftUI, leaving a blank untitled window and no file.
        // Queue it; flushPendingOpens() delivers it once a window registers.
        guard windowHasRegistered else {
            pendingOpens.append(url)
            return
        }
        if EditorSettings.shared.openInNewWindow {
            openInNewWindow(url)
        } else if let store = activeStore {
            store.open(url: url)
        } else {
            openInNewWindow(url)
        }
    }

    func openRecent(_ item: RecentItem) {
        guard let url = RecentsStore.shared.resolve(item) else { return }
        openFile(url: url)
    }

    /// Tear a tab out of its window into a new one, preserving unsaved edits and
    /// (via a stored bookmark) write access to its file.
    func moveToNewWindow(_ doc: Document, from store: EditorStore) {
        guard let openWindow else { return }
        var po = PendingOpen()
        po.title = doc.title
        po.content = doc.content
        po.isModified = doc.isModified
        if let url = doc.fileURL {
            po.bookmark = RecentsStore.shared.bookmark(for: url)
        }
        store.close(doc)
        openWindow(po)
    }

    private func openInNewWindow(_ url: URL) {
        guard let openWindow else { activeStore?.open(url: url); return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bm = try? url.bookmarkData(options: [.withSecurityScope],
                                       includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bm = try? url.bookmarkData()
        #endif
        guard let bm else {
            // Couldn't make a bookmark to carry the file across the window
            // boundary — a nil payload would open a blank session. Fall back to
            // a tab in the active window (or queue for the next one) instead.
            if let store = activeStore {
                store.open(url: url)
            } else {
                pendingOpens.append(url)
            }
            return
        }
        openWindow(PendingOpen(bookmark: bm))
    }

    // MARK: - Quit guard support

    func hasUnsavedChanges() -> Bool {
        stores.allObjects.contains { store in store.documents.contains { $0.isModified } }
    }

    func unsavedPairs() -> [(store: EditorStore, doc: Document)] {
        stores.allObjects.flatMap { store in
            store.documents.filter { $0.isModified }.map { (store, $0) }
        }
    }

    #if os(macOS)
    /// Present an open panel and route the selection per the new-tab/new-window preference.
    func openViaPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .rtf]
        types += ["md", "markdown", "epub"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { openFile(url: $0) } }
    }
    #endif
}
