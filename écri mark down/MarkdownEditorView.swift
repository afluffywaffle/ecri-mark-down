import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Editor + split layout

struct MarkdownEditorView: View {
    var document: Document
    var mode: ViewMode
    @Binding var caret: CaretPosition
    @Binding var topVisibleIndex: Int
    /// Whether this is the currently visible page (iOS paging). The editor claims
    /// the shared action bus only while active, so formatting/find act on it.
    var isActive: Bool = true
    var onEdit: () -> Void

    var contentBinding: Binding<String> {
        Binding(get: { document.content }, set: { document.content = $0 })
    }

    var body: some View {
        switch mode {
        case .source:  editorPane
        case .split:   splitView
        case .preview: previewPane
        }
    }

    var editorPane: some View {
        // Reading EditorSettings.shared here registers observation so the editor
        // restyles when the user changes theme / font size / chrome toggles.
        let settings = EditorSettings.shared
        return ZStack(alignment: .top) {
            SyntaxHighlightingEditor(
                text: contentBinding,
                theme: settings.theme,
                fontSize: settings.fontSize,
                showLineNumbers: settings.showLineNumbers,
                highlightCurrentLine: settings.highlightCurrentLine,
                caret: $caret,
                topVisibleIndex: $topVisibleIndex,
                isActive: isActive,
                onEdit: onEdit
            )
            if settings.stickyHeadings {
                StickyHeadingsView(text: document.content,
                                   topIndex: topVisibleIndex,
                                   theme: settings.theme,
                                   fontSize: settings.fontSize,
                                   leadingInset: settings.showLineNumbers ? 46 : 10)
            }
        }
    }

    var previewPane: some View {
        let settings = EditorSettings.shared
        return ScrollView {
            MarkdownPreviewView(text: document.content,
                                useSerif: settings.useSerifPreview,
                                baseDirectoryURL: document.fileURL?.deletingLastPathComponent())
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(settings.theme.backgroundColor)
    }

    @ViewBuilder
    var splitView: some View {
        #if os(macOS)
        HSplitView {
            editorPane.frame(minWidth: 200)
            previewPane.frame(minWidth: 200)
        }
        #else
        // On a phone, split stacks the editor above the preview (side-by-side would
        // squeeze both to unusable widths).
        VStack(spacing: 0) {
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}

// MARK: - Sticky headings (VS Code-style sticky scroll)

struct MDHeading: Identifiable {
    let id: Int          // character index doubles as a stable id
    let level: Int
    let text: String
    var charIndex: Int { id }
}

/// One-entry memo for `parseHeadings` — it's called several times per keystroke
/// (sticky-headings view + gutter sticky band) with the identical document string;
/// caching the last (input → result) collapses those to a single scan.
private final class HeadingCache {
    static let shared = HeadingCache()
    private var input: String?
    private var result: [MDHeading] = []

    func headings(for source: String, compute: (String) -> [MDHeading]) -> [MDHeading] {
        if let input, input == source { return result }   // memcmp — far cheaper than a scan
        let r = compute(source)
        input = source
        result = r
        return r
    }
}

/// Extract ATX headings with their character offsets, ignoring fenced code blocks.
func parseHeadings(_ source: String) -> [MDHeading] {
    HeadingCache.shared.headings(for: source, compute: parseHeadingsUncached)
}

private func parseHeadingsUncached(_ source: String) -> [MDHeading] {
    var result: [MDHeading] = []
    let ns = source as NSString
    var inFence = false
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                           options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
        let line = ns.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inFence.toggle(); return }
        guard !inFence else { return }
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6, trimmed.count > level,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " else { return }
        let text = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        result.append(MDHeading(id: lineRange.location, level: level, text: text))
    }
    return result
}

/// The nesting chain of headings strictly *above* character offset `boundary`
/// (H1 → H2 → …). A heading whose own line is the top line is excluded — it's
/// visible content, not pinned — which avoids a heading pinning over itself.
func stickyStack(_ headings: [MDHeading], upTo boundary: Int) -> [MDHeading] {
    var stack: [MDHeading] = []
    for h in headings {
        if h.charIndex >= boundary { break }
        while let last = stack.last, last.level >= h.level { stack.removeLast() }
        stack.append(h)
    }
    return stack
}

/// Character offset of the start of the line containing `index`.
func lineStart(in text: String, at index: Int) -> Int {
    let ns = text as NSString
    let loc = min(max(index, 0), ns.length)
    return ns.lineRange(for: NSRange(location: loc, length: 0)).location
}

/// Parent (nearest preceding heading of smaller level) charIndex for each heading, or -1.
func headingParents(_ all: [MDHeading]) -> [Int: Int] {
    var map: [Int: Int] = [:]
    var stack: [MDHeading] = []
    for h in all {
        while let last = stack.last, last.level >= h.level { stack.removeLast() }
        map[h.charIndex] = stack.last?.charIndex ?? -1
        stack.append(h)
    }
    return map
}

/// Headings at the same level sharing the same parent (i.e. jump-between-siblings set).
func siblingHeadings(of h: MDHeading, in all: [MDHeading]) -> [MDHeading] {
    let parents = headingParents(all)
    let target = parents[h.charIndex] ?? -1
    return all.filter { $0.level == h.level && (parents[$0.charIndex] ?? -1) == target }
}

func isCommandKeyDown() -> Bool {
    #if os(macOS)
    return NSEvent.modifierFlags.contains(.command)
    #else
    return false
    #endif
}

struct StickyHeadingsView: View {
    var text: String
    var topIndex: Int
    var theme: EditorTheme
    var fontSize: CGFloat
    var leadingInset: CGFloat

    @State private var settings = EditorSettings.shared
    @State private var outlineFor: MDHeading?

    var body: some View {
        let all = parseHeadings(text)
        let stack = Array(stickyStack(all, upTo: lineStart(in: text, at: topIndex)).suffix(4))
        if !stack.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stack) { h in
                    stickyRow(h, all: all)
                }
                Divider()
            }
            .background(theme.backgroundColor)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Rows the *strict parent* chain of `h` occupies. We scroll `h` to sit right below
    /// its parents; combined with the below-the-bar reference, `h` then pins itself as
    /// the current section and its content shows underneath.
    private func topInset(for h: MDHeading, in all: [MDHeading]) -> CGFloat {
        let parents = headingParents(all)
        var count = 0
        var cur = parents[h.charIndex] ?? -1
        while cur != -1 { count += 1; cur = parents[cur] ?? -1 }
        let rows = min(count, 4)
        return rows > 0 ? CGFloat(rows) * (fontSize * 1.7) : 0
    }

    private func stickyRow(_ h: MDHeading, all: [MDHeading]) -> some View {
        Button {
            handleClick(h, all: all)
        } label: {
            HStack(spacing: 6) {
                Text(String(repeating: "#", count: h.level))
                    .foregroundStyle(Color(platform: theme.heading))
                Text(h.text)
                    .foregroundStyle(Color(platform: theme.foreground))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .padding(.leading, leadingInset + CGFloat(h.level - 1) * 10)
            .padding(.trailing, 12)
            .frame(height: fontSize * 1.7)
            .contentShape(Rectangle())
            .background(theme.backgroundColor)
        }
        .buttonStyle(.plain)
        .help("Click: \(settings.stickyPrimaryAction.label) · ⌘-click or right-click for the other")
        .popover(isPresented: Binding(
            get: { outlineFor?.id == h.id },
            set: { if !$0 { outlineFor = nil } }
        )) {
            outlinePopover(h, all: all)
        }
        .contextMenu {
            Button("Jump to Section") {
                EditorActionBus.shared.scroll(to: h.charIndex, topInset: topInset(for: h, in: all))
            }
            let sibs = siblingHeadings(of: h, in: all)
            if sibs.count > 1 {
                Divider()
                ForEach(sibs) { s in
                    Button(s.text) {
                        EditorActionBus.shared.scroll(to: s.charIndex, topInset: topInset(for: s, in: all))
                    }
                }
            }
        }
    }

    private func handleClick(_ h: MDHeading, all: [MDHeading]) {
        let primaryIsJump = settings.stickyPrimaryAction == .jump
        let doJump = primaryIsJump != isCommandKeyDown()   // ⌘ swaps primary/secondary
        if doJump {
            EditorActionBus.shared.scroll(to: h.charIndex, topInset: topInset(for: h, in: all))
        } else {
            outlineFor = h
        }
    }

    private func outlinePopover(_ h: MDHeading, all: [MDHeading]) -> some View {
        let sibs = siblingHeadings(of: h, in: all)
        return VStack(alignment: .leading, spacing: 1) {
            Text("Headings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(sibs) { s in
                Button {
                    EditorActionBus.shared.scroll(to: s.charIndex, topInset: topInset(for: s, in: all))
                    outlineFor = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.id == h.id ? "checkmark" : "number")
                            .font(.system(size: 10))
                            .foregroundStyle(s.id == h.id ? Color.accentColor : Color.secondary)
                            .frame(width: 14)
                        Text(s.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 320)
    }
}

// MARK: - Block model

private enum MBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(lang: String, code: String)
    case blockquote(text: String)
    case listItem(ordered: Bool, index: Int, text: String)
    /// A GFM task-list item ("- [ ] foo" / "- [x] foo").
    case taskItem(checked: Bool, text: String)
    case horizontalRule
    case image(alt: String, url: String)
    case table(alignments: [TableAlignment], headers: [String], rows: [[String]])
}

private enum TableAlignment {
    case leading, center, trailing
}

// MARK: - Block parser

private enum BlockParser {
    static func parse(_ input: String) -> [MBlock] {
        var result: [MBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        var paraLines: [String] = []

        func flushPara() {
            let s = paraLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(.paragraph(text: s)) }
            paraLines = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var code: [String] = []
                while i < lines.count &&
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                result.append(.codeBlock(lang: lang, code: code.joined(separator: "\n")))
                if i < lines.count { i += 1 }
                continue
            }

            // Heading
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let hCount = hashes.count
            if hCount >= 1, hCount <= 6, trimmed.count > hCount,
               trimmed[trimmed.index(trimmed.startIndex, offsetBy: hCount)] == " " {
                flushPara()
                result.append(.heading(level: hCount,
                                       text: String(trimmed.dropFirst(hCount + 1))))
                i += 1
                continue
            }

            // Horizontal rule (--- / *** / ___ with optional spaces)
            let noSpaces = trimmed.replacingOccurrences(of: " ", with: "")
            if trimmed.count >= 3,
               noSpaces == "---" || noSpaces == "***" || noSpaces == "___" {
                flushPara()
                result.append(.horizontalRule)
                i += 1
                continue
            }

            // GFM table: a "| a | b |" header row followed by a "|---|:--:|" separator row
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               let alignments = tableSeparator(lines[i + 1]) {
                flushPara()
                let headers = splitRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.hasPrefix("|") else { break }
                    rows.append(splitRow(rowTrimmed))
                    i += 1
                }
                result.append(.table(alignments: alignments, headers: headers, rows: rows))
                continue
            }

            // Standalone image line: "![alt](url)"
            if let (alt, url) = standaloneImage(trimmed) {
                flushPara()
                result.append(.image(alt: alt, url: url))
                i += 1
                continue
            }

            // Blockquote
            if line.hasPrefix("> ") || trimmed == ">" {
                flushPara()
                var qLines: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("> ") { qLines.append(String(l.dropFirst(2))); i += 1 }
                    else if l.trimmingCharacters(in: .whitespaces) == ">" { qLines.append(""); i += 1 }
                    else { break }
                }
                result.append(.blockquote(text: qLines.joined(separator: "\n")))
                continue
            }

            // Unordered list item (with GFM task-list checkbox support)
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushPara()
                let rest = String(line.dropFirst(2))
                if let (checked, text) = taskItemPrefix(rest) {
                    result.append(.taskItem(checked: checked, text: text))
                } else {
                    result.append(.listItem(ordered: false, index: 0, text: rest))
                }
                i += 1
                continue
            }

            // Ordered list item  "1. text"
            if let (idx, text) = orderedPrefix(line) {
                flushPara()
                result.append(.listItem(ordered: true, index: idx, text: text))
                i += 1
                continue
            }

            // Blank line — flush paragraph
            if trimmed.isEmpty {
                flushPara()
                i += 1
                continue
            }

            paraLines.append(line)
            i += 1
        }

        flushPara()
        return result
    }

    /// "[ ] rest" / "[x] rest" (case-insensitive checkmark) → (checked, rest).
    private static func taskItemPrefix(_ s: String) -> (Bool, String)? {
        guard s.hasPrefix("["), s.count >= 4 else { return nil }
        let chars = Array(s)
        guard chars[2] == "]", chars[3] == " " else { return nil }
        let mark = chars[1]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", String(chars.dropFirst(4)))
    }

    /// Standalone "![alt](url)" line with nothing else on it.
    private static func standaloneImage(_ trimmed: String) -> (String, String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]"),
              trimmed.index(after: closeBracket) < trimmed.endIndex,
              trimmed[trimmed.index(after: closeBracket)] == "("
        else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracket])
        let urlStart = trimmed.index(closeBracket, offsetBy: 2)
        let urlEnd = trimmed.index(before: trimmed.endIndex)
        guard urlStart <= urlEnd else { return nil }
        var url = String(trimmed[urlStart..<urlEnd])
        // Strip an optional trailing title: url "some title"
        if let quoteIdx = url.firstIndex(of: "\"") {
            url = String(url[..<quoteIdx]).trimmingCharacters(in: .whitespaces)
        }
        return (alt, url)
    }

    /// A table separator row like "|---|:--:|---:|"; returns per-column alignment, or nil if not one.
    private static func tableSeparator(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var result: [TableAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { result.append(.center) }
            else if right { result.append(.trailing) }
            else { result.append(.leading) }
        }
        return result
    }

    /// Split a "| a | b |" row into trimmed cell strings, honoring `\|` as a literal pipe.
    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var chars = Array(line)
        var idx = 0
        // Drop a single leading/trailing "|" (GFM rows are optionally pipe-delimited).
        if chars.first == "|" { chars.removeFirst() }
        if chars.last == "|" { chars.removeLast() }
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\\", idx + 1 < chars.count, chars[idx + 1] == "|" {
                current.append("|")
                idx += 2
                continue
            }
            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            idx += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func orderedPrefix(_ line: String) -> (Int, String)? {
        var j = line.startIndex
        while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
        guard j > line.startIndex,
              j < line.endIndex, line[j] == ".",
              line.index(after: j) < line.endIndex,
              line[line.index(after: j)] == " ",
              let n = Int(String(line[..<j]))
        else { return nil }
        return (n, String(line[line.index(j, offsetBy: 2)...]))
    }
}

// MARK: - Preview renderer

struct MarkdownPreviewView: View {
    var text: String
    var useSerif: Bool = false
    /// The document's on-disk directory, used to resolve relative image paths.
    var baseDirectoryURL: URL?

    private var blocks: [MBlock] { BlockParser.parse(text) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fontDesign(useSerif ? .serif : .default)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MBlock) -> some View {
        switch block {

        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 16 : 10)
                .padding(.bottom, 4)

        case .paragraph(let text):
            Text(inline(text))
                .lineSpacing(3)
                .padding(.vertical, 4)

        case .codeBlock(_, let code):
            Text(code.isEmpty ? " " : code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.vertical, 6)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(inline(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 1)

        case .taskItem(let checked, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(inline(text))
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 1)

        case .image(let alt, let url):
            imageView(alt: alt, url: url)
                .padding(.vertical, 6)

        case .table(let alignments, let headers, let rows):
            tableView(alignments: alignments, headers: headers, rows: rows)
                .padding(.vertical, 6)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func imageView(alt: String, url: String) -> some View {
        if let resolved = resolveImageURL(url) {
            AsyncImage(url: resolved) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                case .failure:
                    brokenImagePlaceholder(alt)
                case .empty:
                    ProgressView().frame(height: 40)
                @unknown default:
                    brokenImagePlaceholder(alt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            brokenImagePlaceholder(alt)
        }
    }

    private func brokenImagePlaceholder(_ alt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(alt.isEmpty ? "Image" : alt)
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Resolve an image reference (remote URL or a path relative to the document's file)
    /// to a URL AsyncImage can load. Local relative paths are resolved against the
    /// document's on-disk directory when known.
    private func resolveImageURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        if let base = baseDirectoryURL {
            return URL(fileURLWithPath: raw, relativeTo: base).absoluteURL
        }
        return URL(fileURLWithPath: raw)
    }

    @ViewBuilder
    private func tableView(alignments: [TableAlignment], headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, alignments.count)
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { col, cell in
                    Text(inline(cell))
                        .font(.system(.body, weight: .semibold))
                        .multilineTextAlignment(textAlignment(for: col, in: alignments))
                        .frame(maxWidth: .infinity, alignment: gridAlignment(for: col, in: alignments))
                }
            }
            Divider().gridCellColumns(max(columnCount, 1))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(inline(col < row.count ? row[col] : ""))
                            .multilineTextAlignment(textAlignment(for: col, in: alignments))
                            .frame(maxWidth: .infinity, alignment: gridAlignment(for: col, in: alignments))
                    }
                }
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func textAlignment(for col: Int, in alignments: [TableAlignment]) -> TextAlignment {
        guard col < alignments.count else { return .leading }
        switch alignments[col] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func gridAlignment(for col: Int, in alignments: [TableAlignment]) -> Alignment {
        guard col < alignments.count else { return .leading }
        switch alignments[col] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case 4: return .title3.bold()
        case 5: return .headline
        default: return .subheadline.bold()
        }
    }

    // Inline markdown (bold, italic, code, links) without block restructuring
    private func inline(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }
}
