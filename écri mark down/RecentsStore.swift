import SwiftUI
import Observation

struct RecentItem: Identifiable, Equatable {
    let url: URL
    let bookmark: Data
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Recently opened files, persisted as security-scoped bookmarks so they can be
/// reopened across launches under the app sandbox.
@Observable
final class RecentsStore {
    static let shared = RecentsStore()

    private let key = "recentFiles"
    private let maxItems = 12
    var items: [RecentItem] = []

    private init() { load() }

    /// Record a freshly opened/saved file. Must be called while the URL is
    /// accessible (e.g. inside a security-scoped access scope from the open panel).
    func add(url: URL) {
        guard let data = makeBookmark(url) else { return }
        items.removeAll { $0.url == url }
        items.insert(RecentItem(url: url, bookmark: data), at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        save()
    }

    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Resolve a stored bookmark back to a usable (security-scoped) URL.
    func resolve(_ item: RecentItem) -> URL? {
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: opts,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            remove(item)
            return nil
        }
        return url
    }

    private func makeBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: [.withSecurityScope],
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private func save() {
        let arr = items.map { ["path": $0.url.path, "bm": $0.bookmark.base64EncodedString()] }
        UserDefaults.standard.set(arr, forKey: key)
    }

    private func load() {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: String]] else { return }
        items = arr.compactMap { d in
            guard let path = d["path"], let bm = d["bm"], let data = Data(base64Encoded: bm) else { return nil }
            return RecentItem(url: URL(fileURLWithPath: path), bookmark: data)
        }
    }
}
