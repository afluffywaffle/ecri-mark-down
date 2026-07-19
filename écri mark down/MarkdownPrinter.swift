import SwiftUI
#if os(macOS)
import AppKit

/// Prints a document as monospaced source with a line-number gutter.
/// Portrait prints a single column; landscape flows the text into two columns
/// per page (chosen from the print panel's orientation control).
enum MarkdownPrinter {
    static func print(_ document: Document) {
        print(content: document.content, title: document.title.isEmpty ? "Untitled" : document.title)
    }

    static func print(content: String, title: String) {
        let info = NSPrintInfo()
        info.leftMargin = 40
        info.rightMargin = 40
        info.topMargin = 52
        info.bottomMargin = 48
        info.horizontalPagination = .clip
        info.verticalPagination = .clip

        let options = HeaderFooterAccessory()
        let view = PrintView(content: content, title: cleanedTitle(title),
                             printInfo: info, options: options)

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.jobTitle = title
        // Surface orientation + paper-size controls so the user can pick Landscape
        // (which flows the text into two columns). The simplified panel hides these
        // by default. The accessory adds our Header/Footer toggle.
        op.printPanel.options.insert([.showsPageSetupAccessory, .showsPreview])
        op.printPanel.addAccessoryController(options)
        op.run()
    }

    /// Turn a filename into a readable header title: drop the extension and swap
    /// underscores/hyphens for spaces (e.g. "Book1_Ch01_v2.md" → "Book1 Ch01 v2").
    private static func cleanedTitle(_ raw: String) -> String {
        let noExt = (raw as NSString).deletingPathExtension
        let spaced = noExt.replacingOccurrences(of: "_", with: " ")
                          .replacingOccurrences(of: "-", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? raw : trimmed
    }
}

/// Print-panel accessory: a single "Print header and footer" checkbox whose state
/// the `PrintView` reads while drawing. Toggling it re-renders the preview.
final class HeaderFooterAccessory: NSViewController, NSPrintPanelAccessorizing {
    @objc dynamic var showHeaderFooter = true

    override func loadView() {
        let checkbox = NSButton(checkboxWithTitle: "Print header and footer",
                                target: nil, action: nil)
        checkbox.bind(.value, to: self, withKeyPath: "showHeaderFooter", options: nil)

        let stack = NSStackView(views: [checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setFrameSize(NSSize(width: 260, height: 56))
        view = stack
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Header & Footer", .itemDescription: showHeaderFooter ? "On" : "Off"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["showHeaderFooter"] }
}

/// A flipped view (origin top-left) that lays the document out into pages and
/// draws them on demand. Pagination is recomputed from the live `NSPrintInfo`,
/// so orientation changes made in the print panel take effect before drawing.
final class PrintView: NSView {
    private let sourceLines: [String]
    private let title: String
    private let info: NSPrintInfo
    private weak var options: HeaderFooterAccessory?

    private let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    private let headerFont = NSFont.systemFont(ofSize: 8, weight: .regular)

    // Computed during layout() and consumed by draw().
    private var pageSize = CGSize.zero
    private var contentOrigin = CGPoint.zero      // top-left of the text area within a page
    private var columnWidth: CGFloat = 0
    private var columnGap: CGFloat = 24
    private var columnsPerPage = 1
    private var gutterWidth: CGFloat = 0
    private var charWidth: CGFloat = 0
    private var lineHeight: CGFloat = 0
    private var rowsPerColumn = 0
    private var visualRows: [VisualRow] = []
    private var pageCount = 1

    /// One drawn line: a wrapped fragment of a source line. `number` is set only on
    /// the first fragment of each source line so wrapped continuations stay ungutter'd.
    private struct VisualRow {
        let number: Int?
        let text: String
    }

    init(content: String, title: String, printInfo: NSPrintInfo, options: HeaderFooterAccessory) {
        self.sourceLines = content.components(separatedBy: "\n")
        self.title = title
        self.info = printInfo
        self.options = options
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    /// The print info the operation is actually using. The panel edits the operation's
    /// own copy, not the instance we passed in, so we must read from the live operation.
    private var activeInfo: NSPrintInfo { NSPrintOperation.current?.printInfo ?? info }

    private func computeLayout() {
        let info = activeInfo
        // Normalize the oriented page size regardless of how paperSize reports it.
        let raw = info.paperSize
        let landscape = info.orientation == .landscape
        let w = landscape ? max(raw.width, raw.height) : min(raw.width, raw.height)
        let h = landscape ? min(raw.width, raw.height) : max(raw.width, raw.height)
        pageSize = CGSize(width: w, height: h)

        columnsPerPage = landscape ? 2 : 1

        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        charWidth = advance > 0 ? advance : font.pointSize * 0.6
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 2

        let left = info.leftMargin
        let right = info.rightMargin
        let top = info.topMargin
        let bottom = info.bottomMargin
        contentOrigin = CGPoint(x: left, y: top)

        let usableWidth = pageSize.width - left - right
        let totalGaps = columnGap * CGFloat(columnsPerPage - 1)
        columnWidth = (usableWidth - totalGaps) / CGFloat(columnsPerPage)

        let usableHeight = pageSize.height - top - bottom
        rowsPerColumn = max(1, Int(usableHeight / lineHeight))

        // Gutter sized to the widest line number.
        let digits = max(2, String(sourceLines.count).count)
        gutterWidth = CGFloat(digits) * charWidth + 8

        let textWidth = max(charWidth, columnWidth - gutterWidth)
        let maxChars = max(1, Int(textWidth / charWidth))

        visualRows = wrap(maxChars: maxChars)

        let rowsPerPage = max(1, rowsPerColumn * columnsPerPage)
        pageCount = max(1, Int(ceil(Double(visualRows.count) / Double(rowsPerPage))))

        setFrameSize(CGSize(width: pageSize.width, height: pageSize.height * CGFloat(pageCount)))
    }

    /// Word-wrap each source line at `maxChars`, breaking on spaces so words stay intact.
    /// Words longer than a column are hard-split as a fallback. Tabs are expanded so
    /// monospaced widths stay predictable.
    private func wrap(maxChars: Int) -> [VisualRow] {
        var rows: [VisualRow] = []
        for (i, rawLine) in sourceLines.enumerated() {
            let lineNumber = i + 1
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            if line.isEmpty {
                rows.append(VisualRow(number: lineNumber, text: ""))
                continue
            }
            let fragments = wrapLine(line, maxChars: maxChars)
            for (j, fragment) in fragments.enumerated() {
                rows.append(VisualRow(number: j == 0 ? lineNumber : nil, text: fragment))
            }
        }
        return rows
    }

    /// Greedy word wrap for a single logical line. Preserves leading indentation on the
    /// first fragment; continuation fragments are hung to align under it.
    private func wrapLine(_ line: String, maxChars: Int) -> [String] {
        // Preserve leading whitespace (Markdown indentation) and hang continuations under it.
        let indentCount = line.prefix { $0 == " " }.count
        let indent = String(repeating: " ", count: min(indentCount, max(0, maxChars - 1)))
        let body = String(line.dropFirst(indentCount))
        let words = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        var fragments: [String] = []
        var current = indent
        var currentIsEmpty = true   // nothing but indent so far

        func flush() {
            fragments.append(current)
            current = indent
            currentIsEmpty = true
        }

        for word in words {
            // Hard-split any single word too long to ever fit a column.
            if word.count > maxChars - indent.count {
                if !currentIsEmpty { flush() }
                var chars = Array(word)
                while !chars.isEmpty {
                    let room = maxChars - indent.count
                    let chunk = String(chars.prefix(room))
                    chars.removeFirst(min(room, chars.count))
                    if chars.isEmpty {
                        current = indent + chunk       // last piece starts a fresh fragment
                        currentIsEmpty = false
                    } else {
                        fragments.append(indent + chunk)
                    }
                }
                continue
            }

            let candidate = currentIsEmpty ? current + word : current + " " + word
            if candidate.count > maxChars, !currentIsEmpty {
                flush()
                current = indent + word
                currentIsEmpty = false
            } else {
                current = candidate
                currentIsEmpty = false
            }
        }
        flush()
        return fragments
    }

    // MARK: - Pagination

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        computeLayout()
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        CGRect(x: 0, y: CGFloat(page - 1) * pageSize.height,
               width: pageSize.width, height: pageSize.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard pageSize.height > 0 else { return }
        let firstPage = max(0, Int(dirtyRect.minY / pageSize.height))
        let lastPage = min(pageCount - 1, Int((dirtyRect.maxY - 0.5) / pageSize.height))
        guard firstPage <= lastPage else { return }
        for page in firstPage...lastPage { drawPage(page) }
    }

    private func drawPage(_ page: Int) {
        let pageTop = CGFloat(page) * pageSize.height
        if options?.showHeaderFooter ?? true {
            drawHeader(pageTop: pageTop)
            drawFooter(pageTop: pageTop, page: page)
        }

        let rowsPerPage = rowsPerColumn * columnsPerPage
        let startRow = page * rowsPerPage

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor
        ]
        let gutterAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for column in 0..<columnsPerPage {
            let columnX = contentOrigin.x + CGFloat(column) * (columnWidth + columnGap)
            let textX = columnX + gutterWidth
            for r in 0..<rowsPerColumn {
                let rowIndex = startRow + column * rowsPerColumn + r
                guard rowIndex < visualRows.count else { break }
                let row = visualRows[rowIndex]
                let y = pageTop + contentOrigin.y + CGFloat(r) * lineHeight

                if let n = row.number {
                    let label = String(n) as NSString
                    let size = label.size(withAttributes: gutterAttrs)
                    // Right-align the number within the gutter.
                    let nx = columnX + (gutterWidth - 6) - size.width
                    label.draw(at: CGPoint(x: nx, y: y), withAttributes: gutterAttrs)
                }
                (row.text as NSString).draw(at: CGPoint(x: textX, y: y), withAttributes: textAttrs)
            }
        }
    }

    private var headerAttrs: [NSAttributedString.Key: Any] {
        [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// Cleaned document title, left-aligned, with a hairline rule beneath it.
    private func drawHeader(pageTop: CGFloat) {
        let y = pageTop + contentOrigin.y - headerFont.pointSize - 10
        (title as NSString).draw(at: CGPoint(x: contentOrigin.x, y: y), withAttributes: headerAttrs)

        let ruleY = pageTop + contentOrigin.y - 6
        drawRule(y: ruleY)
    }

    /// Centered "Page X of N" within the bottom margin, with a hairline rule above it.
    private func drawFooter(pageTop: CGFloat, page: Int) {
        let pageBottom = pageTop + pageSize.height
        let ruleY = pageBottom - activeInfo.bottomMargin + 8
        drawRule(y: ruleY)

        let label = "Page \(page + 1) of \(pageCount)" as NSString
        let size = label.size(withAttributes: headerAttrs)
        let x = (pageSize.width - size.width) / 2
        label.draw(at: CGPoint(x: x, y: ruleY + 6), withAttributes: headerAttrs)
    }

    private func drawRule(y: CGFloat) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: CGPoint(x: contentOrigin.x, y: y))
        path.line(to: CGPoint(x: pageSize.width - activeInfo.rightMargin, y: y))
        path.stroke()
    }
}
#endif
