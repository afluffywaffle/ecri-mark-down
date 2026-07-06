import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Value used to open a window carrying an optional file to load (nil = blank session).
struct PendingOpen: Codable, Hashable {
    var bookmark: Data?
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

    func register(_ store: EditorStore) {
        stores.add(store)
        activeStore = store
    }

    func setActive(_ store: EditorStore) { activeStore = store }

    /// Open a file honoring the "new tab vs new window" preference.
    func openFile(url: URL) {
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
