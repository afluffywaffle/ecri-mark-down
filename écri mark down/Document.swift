import Foundation
import Observation
import UniformTypeIdentifiers
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
class Document: Identifiable {
    let id = UUID()
    var title: String
    var content: String
    var fileURL: URL?
    var isModified = false
    /// True once the user has been warned that saving this document to .docx
    /// loses Markdown/rich formatting. Set on open (for docx files opened as-is)
    /// or after the Save/Save As warning is shown, so we don't nag on every autosave.
    var docxWarningAcknowledged = false

    init(title: String = "Untitled", content: String = "", fileURL: URL? = nil) {
        self.title = title
        self.content = content
        self.fileURL = fileURL
    }

    var displayTitle: String {
        isModified ? "• \(title)" : title
    }

    // Extension to use when saving — RTF/EPUB convert to plain text on open, so save as .txt
    var preferredSaveExtension: String {
        switch fileURL?.pathExtension.lowercased() {
        case "txt":          return "txt"
        case "docx":         return "docx"
        case "rtf", "rtfd",
             "epub":         return "txt"
        default:             return "md"
        }
    }

    // MARK: - Status bar stats

    var wordCount: Int {
        content.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    var lineCount: Int {
        content.isEmpty ? 1 : content.components(separatedBy: "\n").count
    }

    /// Uppercased type label for the status bar (e.g. "MD", "TXT").
    var fileTypeLabel: String {
        let ext = (fileURL?.pathExtension ?? preferredSaveExtension)
        return ext.isEmpty ? "TXT" : ext.uppercased()
    }
}

@Observable
class EditorStore {
    var documents: [Document] = []
    var selectedID: UUID?

    @ObservationIgnored
    private var autosaveWorkItems: [UUID: DispatchWorkItem] = [:]

    init() {
        let first = Document()
        documents.append(first)
        selectedID = first.id
    }

    var selectedDocument: Document? {
        guard let id = selectedID else { return nil }
        return documents.first { $0.id == id }
    }

    func newDocument() {
        let doc = Document()
        documents.append(doc)
        selectedID = doc.id
    }

    /// Adopt an existing document (e.g. a tab moved in from another window),
    /// replacing the initial blank tab if untouched.
    func adopt(_ doc: Document) {
        if documents.count == 1, let first = documents.first, !first.isModified, first.fileURL == nil {
            documents[0] = doc
        } else {
            documents.append(doc)
        }
        selectedID = doc.id
    }

    func close(_ doc: Document) {
        guard let index = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents.remove(at: index)
        if documents.isEmpty {
            newDocument()
        } else {
            selectedID = documents[max(0, index - 1)].id
        }
    }

    func open(url: URL) {
        if let existing = documents.first(where: { $0.fileURL == url }) {
            selectedID = existing.id
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let content = Self.readContent(from: url) else {
            Self.presentOpenFailure(url)
            return
        }
        RecentsStore.shared.add(url: url)
        let doc = Document(title: url.lastPathComponent, content: content, fileURL: url)
        // Already docx on disk — nothing new is being lost by re-saving it, so skip the warning.
        if url.pathExtension.lowercased() == "docx" { doc.docxWarningAcknowledged = true }
        if documents.count == 1,
           let first = documents.first,
           !first.isModified,
           first.fileURL == nil {
            documents[0] = doc
        } else {
            documents.append(doc)
        }
        selectedID = doc.id
    }

    /// Resolve a recent's bookmark and open it.
    func openRecent(_ item: RecentItem) {
        guard let url = RecentsStore.shared.resolve(item) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let existing = documents.first(where: { $0.fileURL == url }) {
            selectedID = existing.id
            return
        }
        guard let content = Self.readContent(from: url) else {
            Self.presentOpenFailure(url)
            return
        }
        RecentsStore.shared.add(url: url)
        let doc = Document(title: url.lastPathComponent, content: content, fileURL: url)
        if url.pathExtension.lowercased() == "docx" { doc.docxWarningAcknowledged = true }
        if documents.count == 1, let first = documents.first, !first.isModified, first.fileURL == nil {
            documents[0] = doc
        } else {
            documents.append(doc)
        }
        selectedID = doc.id
    }

    /// Tell the user a file couldn't be opened instead of failing silently
    /// (a silent failure here is how a "blank window" appears with no document).
    static func presentOpenFailure(_ url: URL?) {
        #if os(macOS)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Open File"
        alert.informativeText = url.map {
            "“\($0.lastPathComponent)” couldn’t be read. It may have been moved, renamed, or be in an unsupported format."
        } ?? "The file couldn’t be found. It may have been moved or renamed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }

    #if os(macOS)
    /// Present an open panel (used by both the toolbar and the File menu).
    func openViaPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .rtf]
        types += ["md", "markdown", "epub", "docx", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Save the selected document, prompting for a location if it is untitled.
    func saveSelected() {
        guard let doc = selectedDocument else { return }
        if doc.fileURL != nil {
            save(doc)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.md"
        panel.allowedContentTypes = savePanelTypes
        if panel.runModal() == .OK, let url = panel.url {
            guard confirmDocxFormattingLossIfNeeded(doc, targetURL: url) else { return }
            doc.fileURL = url
            doc.title = url.lastPathComponent
            save(doc)
            RecentsStore.shared.add(url: url)
        }
    }

    /// Save As — always prompt for a new location, repointing the document there.
    func saveSelectedAs() {
        guard let doc = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent
            ?? "\(doc.title.isEmpty ? "Untitled" : doc.title).\(doc.preferredSaveExtension)"
        panel.allowedContentTypes = savePanelTypes
        if panel.runModal() == .OK, let url = panel.url {
            guard confirmDocxFormattingLossIfNeeded(doc, targetURL: url) else { return }
            doc.fileURL = url
            doc.title = url.lastPathComponent
            save(doc)
            RecentsStore.shared.add(url: url)
        }
    }

    private var savePanelTypes: [UTType] {
        [.plainText] + ["md", "markdown", "txt", "docx"].compactMap { UTType(filenameExtension: $0) }
    }

    /// If the user is saving to a .docx location for the first time, warn that Markdown/rich
    /// formatting won't be preserved — .docx is written as plain Word paragraphs. Returns
    /// false if the user cancels, in which case the caller should abort the save.
    private func confirmDocxFormattingLossIfNeeded(_ doc: Document, targetURL: URL) -> Bool {
        guard targetURL.pathExtension.lowercased() == "docx", !doc.docxWarningAcknowledged else { return true }
        let alert = NSAlert()
        alert.messageText = "Save as Word Document?"
        alert.informativeText = "Markdown formatting (headings, bold, links, tables, etc.) will not be "
            + "preserved — the file will be saved as plain, unstyled paragraphs of text."
        alert.addButton(withTitle: "Save as .docx")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        doc.docxWarningAcknowledged = true
        return true
    }

    /// Reveal the document's on-disk file in Finder, selecting it. No-op for
    /// untitled documents that haven't been saved anywhere yet.
    func revealInFinder(_ doc: Document) {
        guard let url = doc.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Rename a document from its tab. Renames the on-disk file when one exists,
    /// otherwise just updates the in-memory title of an untitled document.
    func rename(_ doc: Document, to rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != doc.title else { return }

        guard let oldURL = doc.fileURL else {
            doc.title = trimmed
            return
        }
        // Preserve the existing extension if the user didn't type one.
        var newName = trimmed
        if (newName as NSString).pathExtension.isEmpty, !oldURL.pathExtension.isEmpty {
            newName += "." + oldURL.pathExtension
        }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        guard newURL != oldURL else { return }

        let accessed = oldURL.startAccessingSecurityScopedResource()
        defer { if accessed { oldURL.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            doc.fileURL = newURL
            doc.title = newURL.lastPathComponent
            RecentsStore.shared.add(url: newURL)
        } catch {
            NSSound.beep()
        }
    }
    #endif

    func save(_ doc: Document) {
        guard let url = doc.fileURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        if url.pathExtension.lowercased() == "docx" {
            guard DocxSupport.write(content: doc.content, to: url) else {
                Self.presentSaveFailure(url, error: nil)
                return
            }
            doc.isModified = false
            return
        }
        #endif
        do {
            try doc.content.write(to: url, atomically: true, encoding: .utf8)
            doc.isModified = false
        } catch {
            // Keep isModified = true so the dirty indicator stays and a later
            // save is retried — a silently swallowed error here is data loss.
            Self.presentSaveFailure(url, error: error)
        }
    }

    /// Tell the user a save failed instead of silently dropping their changes.
    static func presentSaveFailure(_ url: URL, error: Error?) {
        #if os(macOS)
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Save File"
        var info = "“\(url.lastPathComponent)” couldn’t be saved. Your changes are still in the editor — try saving again or use Save As."
        if let error { info += "\n\n(\(error.localizedDescription))" }
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }

    /// Debounced live save. Only saves documents that already have a location and
    /// only when autosave is enabled; untitled documents wait for an explicit Save.
    func scheduleAutosave(_ doc: Document) {
        guard EditorSettings.shared.autosave, doc.fileURL != nil else { return }
        autosaveWorkItems[doc.id]?.cancel()
        let id = doc.id
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc, doc.isModified else { return }
            self.save(doc)
            self.autosaveWorkItems[id] = nil
        }
        autosaveWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - File Reading

    private static func readContent(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "rtf", "rtfd":
            return readRTF(url: url)
        case "epub":
            return readEPUB(url: url)
        case "docx":
            return DocxSupport.read(url: url)
        default:
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
    }

    private static func readRTF(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        return (try? NSAttributedString(data: data, options: opts, documentAttributes: nil))?.string
    }

    #if os(macOS)
    private static func readEPUB(url: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // Extract only text-bearing members — not the whole archive, which can
        // contain arbitrarily large images/fonts/audio. Patterns cover the
        // container/OPF metadata plus the HTML content the spine references.
        unzip.arguments = ["-q", "-o", url.path,
                           "META-INF/container.xml", "*.opf", "*.ncx",
                           "*.xhtml", "*.html", "*.htm",
                           "-d", tmp.path]
        guard (try? unzip.run()) != nil else { return nil }
        unzip.waitUntilExit()
        // 0 = ok, 1 = warnings, 11 = some patterns matched nothing (expected —
        // not every EPUB has every extension). Anything else is a real failure.
        guard [0, 1, 11].contains(unzip.terminationStatus) else { return nil }

        // Try to follow the EPUB spine via container.xml → OPF
        let containerURL = tmp.appendingPathComponent("META-INF/container.xml")
        if let containerXML = try? String(contentsOf: containerURL, encoding: .utf8),
           let opfPath = firstCapture(in: containerXML,
                                      pattern: #"<rootfile[^>]+full-path="([^"]+)""#) {
            let opfURL = tmp.appendingPathComponent(opfPath)
            let opfDir = opfURL.deletingLastPathComponent()
            if let opfXML = try? String(contentsOf: opfURL, encoding: .utf8) {
                let spineText = extractSpineText(opfXML: opfXML, opfDir: opfDir)
                if !spineText.isEmpty { return spineText }
            }
        }

        // Fallback: read all .xhtml/.html files sorted by name
        return extractAllHTMLText(in: tmp)
    }
    #else
    private static func readEPUB(url: URL) -> String? { nil }
    #endif

    // MARK: - EPUB helpers

    private static func extractSpineText(opfXML: String, opfDir: URL) -> String {
        // Build manifest: id → href
        var manifest: [String: String] = [:]
        enumerateCaptures(in: opfXML,
                          pattern: #"<item[^>]+\bid="([^"]+)"[^>]+href="([^"]+)""#,
                          groupCount: 2) { groups in
            manifest[groups[0]] = groups[1]
        }
        // Also handle href before id
        enumerateCaptures(in: opfXML,
                          pattern: #"<item[^>]+\bhref="([^"]+)"[^>]+\bid="([^"]+)""#,
                          groupCount: 2) { groups in
            manifest[groups[1]] = groups[0]
        }

        // Get ordered spine idrefs
        var spineIDs: [String] = []
        enumerateCaptures(in: opfXML,
                          pattern: #"<itemref[^>]+idref="([^"]+)""#,
                          groupCount: 1) { groups in
            spineIDs.append(groups[0])
        }

        var texts: [String] = []
        for id in spineIDs {
            guard let href = manifest[id] else { continue }
            let fileURL = opfDir.appendingPathComponent(href)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let stripped = stripHTML(html)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(stripped)
            }
        }
        return texts.joined(separator: "\n\n")
    }

    private static func extractAllHTMLText(in dir: URL) -> String {
        let excluded = Set(["toc", "nav", "ncx", "cover"])
        var results: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            let ext = file.pathExtension.lowercased()
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            guard (ext == "xhtml" || ext == "html") && !excluded.contains(name),
                  let html = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let stripped = stripHTML(html)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append((name, stripped))
            }
        }
        results.sort { $0.0 < $1.0 }
        return results.map(\.1).joined(separator: "\n\n")
    }

    // MARK: - HTML stripping

    private static func stripHTML(_ html: String) -> String {
        var s = html
        // Drop <head> entirely
        s = replacing(s, pattern: #"<head[\s\S]*?</head>"#, options: .caseInsensitive, with: "")
        // Drop <script> and <style> blocks
        s = replacing(s, pattern: #"<(script|style)[\s\S]*?</\1>"#, options: .caseInsensitive, with: "")
        // Block-level close tags → newline
        s = replacing(s, pattern: #"</(p|div|h[1-6]|li|blockquote|tr|section|article)>"#,
                      options: .caseInsensitive, with: "\n")
        // <br> → newline
        s = replacing(s, pattern: #"<br\s*/?>"#, options: .caseInsensitive, with: "\n")
        // Remove remaining tags
        s = replacing(s, pattern: "<[^>]+>", with: "")
        // Decode common entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&#160;", " "), ("&quot;", "\""),
            ("&apos;", "'"), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}")
        ]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        // Collapse blank lines
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var prevBlank = false
        for line in lines {
            let blank = line.isEmpty
            if blank && prevBlank { continue }
            out.append(line)
            prevBlank = blank
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helpers

    private static func replacing(_ s: String, pattern: String,
                                   options: NSRegularExpression.Options = [],
                                   with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: replacement)
    }

    private static func firstCapture(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return String(s[range])
    }

    private static func enumerateCaptures(in s: String, pattern: String, groupCount: Int,
                                           handler: ([String]) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        re.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
            guard let match, match.numberOfRanges >= groupCount + 1 else { return }
            let groups = (1...groupCount).compactMap { i -> String? in
                guard let r = Range(match.range(at: i), in: s) else { return nil }
                return String(s[r])
            }
            guard groups.count == groupCount else { return }
            handler(groups)
        }
    }
}

struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var content: String

    init(content: String = "") { self.content = content }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        content = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8)!)
    }
}
