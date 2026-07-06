import SwiftUI

// MARK: - Authoring actions

enum EditorAction {
    case wrap(String, String)        // bold **, italic *, code `, strike ~~
    case heading(Int)                // set line(s) to heading level 1…3
    case toggleLinePrefix(String)    // "- " bullet, "> " quote
    case link
}

/// Bridges the formatting toolbar/shortcuts to whichever editor is currently active.
/// Only one document editor is live at a time (the selected tab), so a single
/// handler slot is sufficient.
final class EditorActionBus {
    static let shared = EditorActionBus()
    var handler: ((EditorAction) -> Void)?
    /// Scroll the active editor so the given character index sits `topInset` points
    /// below the top (used to clear the pinned sticky-heading bar).
    var scrollHandler: ((Int, CGFloat) -> Void)?
    /// Trigger a find-bar action on the active editor. The Int is the platform
    /// find-action tag (macOS: NSTextFinder.Action raw value).
    var findHandler: ((Int) -> Void)?
    /// Select and scroll a text range into view (used by the find sidebar).
    var revealHandler: ((NSRange) -> Void)?
    /// Replace a single range with a string (undoable).
    var replaceHandler: ((NSRange, String) -> Void)?
    /// Replace every occurrence of a query with a replacement (one undoable edit).
    var replaceAllHandler: ((String, String, Bool) -> Void)?

    func perform(_ action: EditorAction) { handler?(action) }
    func scroll(to index: Int, topInset: CGFloat = 0) { scrollHandler?(index, topInset) }
    func find(_ tag: Int) { findHandler?(tag) }
    func reveal(_ range: NSRange) { revealHandler?(range) }
    func replace(_ range: NSRange, with string: String) { replaceHandler?(range, string) }
    func replaceAll(query: String, with replacement: String, caseSensitive: Bool) {
        replaceAllHandler?(query, replacement, caseSensitive)
    }
}

/// A pure description of the edit to apply — computed independently of the platform
/// text view, then applied (with undo) by each coordinator.
struct MDEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

func markdownEdit(_ action: EditorAction, text: String, selection sel: NSRange) -> MDEdit {
    let ns = text as NSString

    switch action {
    case .wrap(let pre, let suf):
        let selected = ns.substring(with: sel)
        let replacement = pre + selected + suf
        let preLen = (pre as NSString).length
        let selection: NSRange = selected.isEmpty
            ? NSRange(location: sel.location + preLen, length: 0)
            : NSRange(location: sel.location + preLen, length: (selected as NSString).length)
        return MDEdit(range: sel, replacement: replacement, selection: selection)

    case .link:
        let selected = ns.substring(with: sel)
        if selected.isEmpty {
            return MDEdit(range: sel, replacement: "[](url)",
                          selection: NSRange(location: sel.location + 1, length: 0))
        }
        let replacement = "[\(selected)](url)"
        let urlLoc = sel.location + 1 + (selected as NSString).length + 2
        return MDEdit(range: sel, replacement: replacement,
                      selection: NSRange(location: urlLoc, length: 3))

    case .heading(let level):
        return lineEdit(ns: ns, sel: sel) { line in
            let stripped = line.replacingOccurrences(of: "^#{1,6}[ \\t]+", with: "",
                                                     options: .regularExpression)
            return String(repeating: "#", count: level) + " " + stripped
        }

    case .toggleLinePrefix(let prefix):
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hadNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadNewline { lines.removeLast() }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allPrefixed = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
        let out = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            return allPrefixed ? String(line.dropFirst(prefix.count)) : prefix + line
        }
        return assembled(out, hadNewline: hadNewline, lineRange: lineRange)
    }
}

private func lineEdit(ns: NSString, sel: NSRange, transform: (String) -> String) -> MDEdit {
    let lineRange = ns.lineRange(for: sel)
    let block = ns.substring(with: lineRange)
    let hadNewline = block.hasSuffix("\n")
    var lines = block.components(separatedBy: "\n")
    if hadNewline { lines.removeLast() }
    let out = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : transform($0) }
    return assembled(out, hadNewline: hadNewline, lineRange: lineRange)
}

private func assembled(_ lines: [String], hadNewline: Bool, lineRange: NSRange) -> MDEdit {
    var replacement = lines.joined(separator: "\n")
    if hadNewline { replacement += "\n" }
    let caret = lineRange.location + (replacement as NSString).length - (hadNewline ? 1 : 0)
    return MDEdit(range: lineRange, replacement: replacement,
                  selection: NSRange(location: max(lineRange.location, caret), length: 0))
}

// MARK: - Formatting toolbar

struct FormattingBar: View {
    var body: some View {
        HStack(spacing: 2) {
            btn("bold", "Bold (⌘B)", .command, "b") { EditorActionBus.shared.perform(.wrap("**", "**")) }
            btn("italic", "Italic (⌘I)", .command, "i") { EditorActionBus.shared.perform(.wrap("*", "*")) }
            btn("chevron.left.forwardslash.chevron.right", "Inline Code (⌘E)", .command, "e") {
                EditorActionBus.shared.perform(.wrap("`", "`"))
            }
            btn("strikethrough", "Strikethrough") { EditorActionBus.shared.perform(.wrap("~~", "~~")) }

            divider
            btn("1.square", "Heading 1") { EditorActionBus.shared.perform(.heading(1)) }
            btn("2.square", "Heading 2") { EditorActionBus.shared.perform(.heading(2)) }
            btn("list.bullet", "Bullet List") { EditorActionBus.shared.perform(.toggleLinePrefix("- ")) }
            btn("text.quote", "Quote") { EditorActionBus.shared.perform(.toggleLinePrefix("> ")) }
            btn("link", "Link (⌘K)", .command, "k") { EditorActionBus.shared.perform(.link) }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.bar)
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func btn(_ symbol: String, _ help: String,
                     _ mods: EventModifiers? = nil, _ key: Character = " ",
                     action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)

        if let mods {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: mods)
        } else {
            button
        }
    }
}
