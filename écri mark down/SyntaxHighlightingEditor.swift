import SwiftUI

// MARK: - Shared helpers

/// Number of newlines in `ns` before `location` (→ 0-based line index).
fileprivate func newlineCount(_ ns: NSString, upTo location: Int) -> Int {
    var count = 0
    var i = 0
    let loc = min(max(location, 0), ns.length)
    while i < loc {
        if ns.character(at: i) == 10 { count += 1 }
        i += 1
    }
    return count
}

/// 1-based line/column for a caret at `location`.
fileprivate func caretPosition(in text: String, location: Int) -> CaretPosition {
    let ns = text as NSString
    let loc = min(max(location, 0), ns.length)
    let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
    let line = 1 + newlineCount(ns, upTo: loc)
    return CaretPosition(line: line, column: loc - lineStart + 1)
}

// MARK: - Syntax highlighter (theme + font-size aware)

enum SyntaxRole {
    case codeBlock, heading, bold, italic, inlineCode, blockquote, listMarker, link, strike, horizontalRule
}

enum Highlighter {

    static func baseFont(_ size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static func boldFont(_ size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }
    static func italicFont(_ size: CGFloat) -> PlatformFont {
        let base = baseFont(size)
        #if os(macOS)
        let d = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: d, size: size) ?? base
        #else
        guard let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: d, size: size)
        #endif
    }

    private struct CompiledRule { let regex: NSRegularExpression; let role: SyntaxRole }

    private static let rules: [CompiledRule] = {
        func rule(_ pattern: String,
                  _ opts: NSRegularExpression.Options = [],
                  _ role: SyntaxRole) -> CompiledRule? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
            return CompiledRule(regex: re, role: role)
        }
        return [
            // Fenced code blocks first — keeps inner content from matching inline rules
            rule("```[\\s\\S]*?```", [.dotMatchesLineSeparators], .codeBlock),
            rule("^(?: {4}|\\t).+$", [.anchorsMatchLines], .codeBlock),
            rule("^#{1,6}\\s.*$", [.anchorsMatchLines], .heading),
            rule("(\\*\\*|__)(?!\\s).+?(?<!\\s)(\\*\\*|__)", [], .bold),
            rule("(?<!\\*)\\*(?!\\*)[^*\\n]+\\*(?!\\*)|(?<!_)_(?!_)[^_\\n]+_(?!_)", [], .italic),
            rule("`[^`\\n]+`", [], .inlineCode),
            rule("^>.*$", [.anchorsMatchLines], .blockquote),
            rule("^[ \\t]*([\\-\\*\\+]|\\d+\\.)\\s", [.anchorsMatchLines], .listMarker),
            rule("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)", [], .link),
            rule("~~[^~\\n]+~~", [], .strike),
            rule("^(-{3,}|\\*{3,}|_{3,})\\s*$", [.anchorsMatchLines], .horizontalRule),
        ].compactMap { $0 }
    }()

    private static func attributes(for role: SyntaxRole,
                                   theme: EditorTheme,
                                   size: CGFloat) -> [NSAttributedString.Key: Any] {
        switch role {
        case .codeBlock:      return [.foregroundColor: theme.codeBlock, .font: baseFont(size)]
        case .heading:        return [.foregroundColor: theme.heading, .font: boldFont(size)]
        case .bold:           return [.font: boldFont(size)]
        case .italic:         return [.font: italicFont(size), .foregroundColor: theme.emphasisMuted]
        case .inlineCode:     return [.foregroundColor: theme.inlineCode]
        case .blockquote:     return [.foregroundColor: theme.quote, .font: italicFont(size)]
        case .listMarker:     return [.foregroundColor: theme.listMarker]
        case .link:           return [.foregroundColor: theme.link]
        case .strike:         return [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .foregroundColor: theme.strike]
        case .horizontalRule: return [.foregroundColor: theme.quote]
        }
    }

    static func apply(to storage: NSTextStorage, theme: EditorTheme, fontSize: CGFloat) {
        let str = storage.string
        guard !str.isEmpty else { return }
        let full = NSRange(location: 0, length: (str as NSString).length)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont(fontSize), .foregroundColor: theme.foreground], range: full)
        for rule in rules {
            let attrs = attributes(for: rule.role, theme: theme, size: fontSize)
            rule.regex.enumerateMatches(in: str, range: full) { match, _, _ in
                guard let r = match?.range else { return }
                storage.addAttributes(attrs, range: r)
            }
        }
        storage.endEditing()
    }
}

// ============================================================================
// MARK: - macOS
// ============================================================================

#if os(macOS)

/// NSTextView that paints a full-width wash behind the caret's line.
final class LineHighlightTextView: NSTextView {
    var highlightCurrentLine = true
    var currentLineColor: NSColor = .clear

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightCurrentLine,
              let lm = layoutManager,
              let container = textContainer else { return }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        r.origin.x = 0
        r.origin.y += textContainerInset.height
        r.size.width = bounds.width
        if r.height < 1 {
            r.size.height = lm.defaultLineHeight(for: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        currentLineColor.setFill()
        NSBezierPath(rect: r).fill()
    }
}

/// Left gutter drawing line numbers as a plain sibling view (NOT an NSRulerView),
/// so nothing spans the full window height or shows through the translucent title bar.
final class MacGutterView: NSView {
    weak var textView: NSTextView?
    var numberFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var textColor: NSColor = .tertiaryLabelColor
    var activeColor: NSColor = .labelColor
    var backgroundColor: NSColor = .textBackgroundColor
    var highlightActive = true
    /// Height of the pinned sticky-heading bar; numbers within it are suppressed and
    /// the band is filled to match the editor background (so nothing peeks through).
    var topSkip: CGFloat = 0
    var topSkipColor: NSColor = .clear

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }

        let ns = tv.string as NSString
        let inset = tv.textContainerInset.height
        let offsetY = tv.visibleRect.minY
        let caretLineStart = ns.lineRange(for: NSRange(location: min(tv.selectedRange().location, ns.length),
                                                       length: 0)).location

        if lm.numberOfGlyphs == 0 {
            drawNumber(1, atY: inset - offsetY, height: numberFont.pointSize * 1.6, active: true)
            return
        }

        let glyphRange = lm.glyphRange(forBoundingRect: tv.visibleRect, in: container)
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, gRange, _ in
            let charRange = lm.characterRange(forGlyphRange: gRange, actualGlyphRange: nil)
            let lineStart = ns.lineRange(for: NSRange(location: charRange.location, length: 0)).location
            guard lineStart == charRange.location else { return }
            let lineNo = 1 + newlineCount(ns, upTo: lineStart)
            self.drawNumber(lineNo, atY: fragRect.minY + inset - offsetY, height: fragRect.height,
                            active: lineStart == caretLineStart)
        }
        if NSMaxRange(glyphRange) >= lm.numberOfGlyphs {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 {
                drawNumber(1 + newlineCount(ns, upTo: ns.length), atY: extra.minY + inset - offsetY,
                           height: extra.height, active: caretLineStart == ns.length)
            }
        }

        // Blank out the band under the pinned sticky-heading bar so no numbers peek through.
        if topSkip > 0 {
            topSkipColor.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: topSkip)).fill()
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat, active: Bool) {
        if y + height * 0.5 < topSkip { return }   // inside the sticky band — suppressed
        let color = (active && highlightActive) ? activeColor : textColor
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
        let s = "\(number)" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.width - size.width - 6, y: y + (height - size.height) / 2),
               withAttributes: attrs)
    }
}

/// Lays out the scrolling text view beside the gutter (gutter is a sibling, not a ruler).
final class MacEditorContainer: NSView {
    let scroll: NSScrollView
    let gutter: MacGutterView
    var showLineNumbers = true
    var gutterWidth: CGFloat = 40

    init(scroll: NSScrollView, gutter: MacGutterView) {
        self.scroll = scroll
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(scroll)
        addSubview(gutter)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gw = showLineNumbers ? gutterWidth : 0
        gutter.isHidden = !showLineNumbers
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: bounds.height)
        scroll.frame = NSRect(x: gw, y: 0, width: bounds.width - gw, height: bounds.height)
    }
}

struct SyntaxHighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    var theme: EditorTheme
    var fontSize: CGFloat
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    @Binding var caret: CaretPosition
    @Binding var topVisibleIndex: Int
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MacEditorContainer {
        // Force a TextKit 1 stack so the layoutManager APIs used by the gutter are available.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = LineHighlightTextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.isRichText = true
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.string = text

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = false

        let gutter = MacGutterView()
        gutter.textView = tv

        let containerView = MacEditorContainer(scroll: scroll, gutter: gutter)
        context.coordinator.textView = tv
        context.coordinator.gutter = gutter
        context.coordinator.container = containerView
        EditorActionBus.shared.handler = { [weak coord = context.coordinator] action in
            coord?.performAction(action)
        }
        EditorActionBus.shared.scrollHandler = { [weak coord = context.coordinator] index, topInset in
            coord?.scrollTo(index, topInset: topInset)
        }
        EditorActionBus.shared.findHandler = { [weak coord = context.coordinator] tag in
            coord?.performFind(tag)
        }
        EditorActionBus.shared.revealHandler = { [weak coord = context.coordinator] range in
            coord?.revealRange(range)
        }
        EditorActionBus.shared.replaceHandler = { [weak coord = context.coordinator] range, string in
            coord?.replace(range: range, with: string)
        }
        EditorActionBus.shared.replaceAllHandler = { [weak coord = context.coordinator] query, replacement, caseSensitive in
            coord?.replaceAll(query: query, with: replacement, caseSensitive: caseSensitive)
        }

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        applyStyling(container: containerView)
        if let s = tv.textStorage { Highlighter.apply(to: s, theme: theme, fontSize: fontSize) }
        DispatchQueue.main.async { context.coordinator.reportTop() }
        return containerView
    }

    func updateNSView(_ containerView: MacEditorContainer, context: Context) {
        context.coordinator.parent = self
        guard let tv = containerView.scroll.documentView as? LineHighlightTextView else { return }

        var didReplaceText = false
        if !context.coordinator.isUpdating, tv.string != text {
            let saved = tv.selectedRanges
            tv.string = text
            let len = (tv.string as NSString).length
            tv.selectedRanges = saved.compactMap { v in
                let r = v.rangeValue
                guard r.location <= len else { return nil }
                let end = min(r.location + r.length, len)
                return NSValue(range: NSRange(location: r.location, length: end - r.location))
            }
            didReplaceText = true
        }

        let styleChanged = context.coordinator.styleSignature != styleSignature
        if styleChanged || didReplaceText {
            applyStyling(container: containerView)
            if let s = tv.textStorage { Highlighter.apply(to: s, theme: theme, fontSize: fontSize) }
            context.coordinator.styleSignature = styleSignature
        }
        containerView.needsLayout = true
        tv.needsDisplay = true
        containerView.gutter.needsDisplay = true
        context.coordinator.updateGutterTopSkip(topCharIndex: topVisibleIndex)
    }

    /// Changes to any of these require a restyle/re-highlight.
    private var styleSignature: String {
        "\(theme.rawValue)|\(fontSize)|\(showLineNumbers)|\(highlightCurrentLine)"
    }

    private func applyStyling(container: MacEditorContainer) {
        guard let tv = container.scroll.documentView as? LineHighlightTextView else { return }
        tv.backgroundColor = theme.background
        tv.insertionPointColor = theme.foreground
        tv.highlightCurrentLine = highlightCurrentLine
        tv.currentLineColor = highlightCurrentLine ? theme.currentLine : .clear
        container.scroll.backgroundColor = theme.background

        let g = container.gutter
        g.numberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
        g.textColor = theme.gutterText
        g.activeColor = theme.gutterActiveText
        g.backgroundColor = theme.gutterBackground
        g.highlightActive = highlightCurrentLine

        container.showLineNumbers = showLineNumbers
        let lineCount = max(1, (tv.string as NSString).components(separatedBy: "\n").count)
        let digits = max(2, "\(lineCount)".count)
        let sample = String(repeating: "8", count: digits) as NSString
        container.gutterWidth = max(30, sample.size(withAttributes: [.font: g.numberFont]).width + 16)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightingEditor
        var isUpdating = false
        weak var gutter: MacGutterView?
        weak var container: MacEditorContainer?
        weak var textView: NSTextView?
        var styleSignature = ""

        init(_ parent: SyntaxHighlightingEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = tv.string
            parent.onEdit()
            isUpdating = false
            if let s = tv.textStorage {
                let theme = parent.theme, size = parent.fontSize
                DispatchQueue.main.async { Highlighter.apply(to: s, theme: theme, fontSize: size) }
            }
            gutter?.needsDisplay = true
            reportCaret(tv)
            reportTop()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tv.needsDisplay = true
            gutter?.needsDisplay = true
            reportCaret(tv)
        }

        private func reportCaret(_ tv: NSTextView) {
            let pos = caretPosition(in: tv.string, location: tv.selectedRange().location)
            guard parent.caret != pos else { return }
            let binding = parent.$caret
            DispatchQueue.main.async { binding.wrappedValue = pos }
        }

        func reportTop() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            // Reference the first line *below* the pinned sticky bar, not the hidden y=0
            // line — so the sticky context updates as headings meet the bar, not after
            // they've scrolled all the way behind it.
            let barHeight = gutter?.topSkip ?? 0
            let y = max(0, tv.visibleRect.minY - tv.textContainerInset.height + barHeight) + 1
            let glyph = lm.glyphIndex(for: CGPoint(x: 2, y: y), in: tc)
            let idx = lm.characterIndexForGlyph(at: glyph)
            updateGutterTopSkip(topCharIndex: idx)
            guard parent.topVisibleIndex != idx else { return }
            let binding = parent.$topVisibleIndex
            DispatchQueue.main.async { binding.wrappedValue = idx }
        }

        /// Match the gutter's blanked top band to the pinned sticky-heading bar height.
        func updateGutterTopSkip(topCharIndex: Int) {
            guard let g = gutter, let tv = textView else { return }
            if EditorSettings.shared.stickyHeadings {
                let text = tv.string
                let stack = stickyStack(parseHeadings(text), upTo: lineStart(in: text, at: topCharIndex))
                let count = min(stack.count, 4)
                g.topSkip = count > 0 ? CGFloat(count) * (parent.fontSize * 1.7) + 1 : 0
            } else {
                g.topSkip = 0
            }
            g.topSkipColor = parent.theme.background
            g.needsDisplay = true
        }

        @objc func boundsChanged(_ notification: Notification) {
            gutter?.needsDisplay = true
            reportTop()
        }

        func performAction(_ action: EditorAction) {
            guard let tv = textView else { return }
            let edit = markdownEdit(action, text: tv.string, selection: tv.selectedRange())
            if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                tv.replaceCharacters(in: edit.range, with: edit.replacement)
                tv.didChangeText()
                tv.setSelectedRange(edit.selection)
            }
            parent.text = tv.string
            parent.onEdit()
            if let s = tv.textStorage {
                Highlighter.apply(to: s, theme: parent.theme, fontSize: parent.fontSize)
            }
            gutter?.needsDisplay = true
            reportCaret(tv)
        }

        func scrollTo(_ index: Int, topInset: CGFloat) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            let loc = min(max(index, 0), ns.length)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            guard lm.numberOfGlyphs > 0 else { tv.scroll(.zero); return }
            let glyphIdx = min(lm.glyphIndexForCharacter(at: loc), lm.numberOfGlyphs - 1)
            var rect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            rect.origin.y += tv.textContainerInset.height
            tv.scroll(NSPoint(x: 0, y: max(0, rect.origin.y - topInset)))
            gutter?.needsDisplay = true
            reportTop()
            reportCaret(tv)
        }

        func performFind(_ tag: Int) {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.tag = tag
            tv.performTextFinderAction(item)
        }

        func revealRange(_ range: NSRange) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let len = (tv.string as NSString).length
            let loc = min(range.location, len)
            let safe = NSRange(location: loc, length: min(range.length, len - loc))
            tv.setSelectedRange(safe)
            guard lm.numberOfGlyphs > 0 else { return }
            let glyphIdx = min(lm.glyphIndexForCharacter(at: loc), lm.numberOfGlyphs - 1)
            var rect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            rect.origin.y += tv.textContainerInset.height
            let inset = (gutter?.topSkip ?? 0) + 60
            tv.scroll(NSPoint(x: 0, y: max(0, rect.origin.y - inset)))
            tv.showFindIndicator(for: safe)
            gutter?.needsDisplay = true
            reportTop()
            reportCaret(tv)
        }

        func replace(range: NSRange, with string: String) {
            guard let tv = textView else { return }
            let len = (tv.string as NSString).length
            guard range.location + range.length <= len else { return }
            if tv.shouldChangeText(in: range, replacementString: string) {
                tv.replaceCharacters(in: range, with: string)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location, length: (string as NSString).length))
            }
            syncAfterEdit(tv)
        }

        func replaceAll(query: String, with replacement: String, caseSensitive: Bool) {
            guard let tv = textView, !query.isEmpty else { return }
            let ns = tv.string as NSString
            let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let full = NSRange(location: 0, length: ns.length)
            let newString = ns.replacingOccurrences(of: query, with: replacement, options: opts, range: full)
            guard newString != tv.string else { return }
            if tv.shouldChangeText(in: full, replacementString: newString) {
                tv.replaceCharacters(in: full, with: newString)
                tv.didChangeText()
            }
            syncAfterEdit(tv)
        }

        private func syncAfterEdit(_ tv: NSTextView) {
            parent.text = tv.string
            parent.onEdit()
            if let s = tv.textStorage {
                Highlighter.apply(to: s, theme: parent.theme, fontSize: parent.fontSize)
            }
            gutter?.needsDisplay = true
            reportTop()
            reportCaret(tv)
        }
    }
}

// ============================================================================
// MARK: - iOS / iPadOS / visionOS
// ============================================================================

#else

/// Left gutter drawing line numbers, synced to the text view's scroll offset.
final class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    var numberFont: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var textColor: UIColor = .tertiaryLabel
    var activeColor: UIColor = .label
    var backgroundColor2: UIColor = .secondarySystemBackground
    var highlightActive = true
    var topSkip: CGFloat = 0
    var topSkipColor: UIColor = .clear

    override func draw(_ rect: CGRect) {
        guard let tv = textView, let ctx = UIGraphicsGetCurrentContext() else { return }
        backgroundColor2.setFill()
        ctx.fill(bounds)
        defer {
            if topSkip > 0 {
                topSkipColor.setFill()
                UIGraphicsGetCurrentContext()?.fill(CGRect(x: 0, y: 0, width: bounds.width, height: topSkip))
            }
        }

        let lm = tv.layoutManager
        let container = tv.textContainer
        let ns = tv.text as NSString
        let inset = tv.textContainerInset.top
        let offsetY = tv.contentOffset.y
        let caretLineStart = ns.lineRange(for: NSRange(location: min(tv.selectedRange.location, ns.length),
                                                       length: 0)).location

        if lm.numberOfGlyphs == 0 {
            drawNumber(1, atY: inset - offsetY, height: numberFont.lineHeight, active: true)
            return
        }

        let visible = CGRect(x: 0, y: offsetY, width: tv.bounds.width, height: tv.bounds.height)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: container)
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, gRange, _ in
            let charRange = lm.characterRange(forGlyphRange: gRange, actualGlyphRange: nil)
            let lineStart = ns.lineRange(for: NSRange(location: charRange.location, length: 0)).location
            guard lineStart == charRange.location else { return }
            let lineNo = 1 + newlineCount(ns, upTo: lineStart)
            self.drawNumber(lineNo, atY: fragRect.minY + inset - offsetY, height: fragRect.height,
                            active: lineStart == caretLineStart)
        }
        if NSMaxRange(glyphRange) >= lm.numberOfGlyphs {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 {
                drawNumber(1 + newlineCount(ns, upTo: ns.length), atY: extra.minY + inset - offsetY,
                           height: extra.height, active: caretLineStart == ns.length)
            }
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat, active: Bool) {
        if y + height * 0.5 < topSkip { return }
        let color = (active && highlightActive) ? activeColor : textColor
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
        let s = "\(number)" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.width - size.width - 6, y: y + (height - size.height) / 2),
               withAttributes: attrs)
    }
}

/// Container laying out the text view beside the gutter.
final class EditorContainerView: UIView {
    let textView: UITextView
    let gutter: LineNumberGutterView
    let currentLineView = UIView()
    var showLineNumbers = true
    var gutterWidth: CGFloat = 44

    init(textView: UITextView, gutter: LineNumberGutterView) {
        self.textView = textView
        self.gutter = gutter
        super.init(frame: .zero)
        currentLineView.isUserInteractionEnabled = false
        textView.insertSubview(currentLineView, at: 0)
        addSubview(textView)
        addSubview(gutter)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gw = showLineNumbers ? gutterWidth : 0
        gutter.isHidden = !showLineNumbers
        gutter.frame = CGRect(x: 0, y: 0, width: gw, height: bounds.height)
        textView.frame = CGRect(x: gw, y: 0, width: bounds.width - gw, height: bounds.height)
    }
}

struct SyntaxHighlightingEditor: UIViewRepresentable {
    @Binding var text: String
    var theme: EditorTheme
    var fontSize: CGFloat
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    @Binding var caret: CaretPosition
    @Binding var topVisibleIndex: Int
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorContainerView {
        // Force a TextKit 1 stack for layoutManager access.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = UITextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 8)
        tv.isFindInteractionEnabled = true
        tv.text = text

        let gutter = LineNumberGutterView()
        gutter.textView = tv

        let containerView = EditorContainerView(textView: tv, gutter: gutter)
        applyStyling(container: containerView, context: context)
        Highlighter.apply(to: tv.textStorage, theme: theme, fontSize: fontSize)
        EditorActionBus.shared.handler = { [weak coord = context.coordinator] action in
            coord?.performAction(action)
        }
        EditorActionBus.shared.scrollHandler = { [weak coord = context.coordinator] index, topInset in
            coord?.scrollTo(index, topInset: topInset)
        }
        EditorActionBus.shared.findHandler = { [weak coord = context.coordinator] tag in
            coord?.performFind(tag)
        }
        EditorActionBus.shared.revealHandler = { [weak coord = context.coordinator] range in
            coord?.revealRange(range)
        }
        return containerView
    }

    func updateUIView(_ containerView: EditorContainerView, context: Context) {
        context.coordinator.parent = self
        let tv = containerView.textView

        var didReplaceText = false
        if !context.coordinator.isUpdating, tv.text != text {
            let sel = tv.selectedRange
            tv.text = text
            if sel.location <= (tv.text as NSString).length { tv.selectedRange = sel }
            didReplaceText = true
        }

        let styleChanged = context.coordinator.styleSignature != styleSignature
        if styleChanged || didReplaceText {
            applyStyling(container: containerView, context: context)
            Highlighter.apply(to: tv.textStorage, theme: theme, fontSize: fontSize)
            context.coordinator.styleSignature = styleSignature
        }
        containerView.setNeedsLayout()
        containerView.gutter.setNeedsDisplay()
        context.coordinator.updateCurrentLine()
        context.coordinator.updateGutterTopSkip(topCharIndex: topVisibleIndex)
    }

    private var styleSignature: String {
        "\(theme.rawValue)|\(fontSize)|\(showLineNumbers)|\(highlightCurrentLine)"
    }

    private func applyStyling(container: EditorContainerView, context: Context) {
        let tv = container.textView
        tv.backgroundColor = theme.background
        tv.tintColor = theme.foreground
        container.showLineNumbers = showLineNumbers
        container.currentLineView.backgroundColor = highlightCurrentLine ? theme.currentLine : .clear
        container.currentLineView.isHidden = !highlightCurrentLine

        let g = container.gutter
        g.numberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
        g.textColor = theme.gutterText
        g.activeColor = theme.gutterActiveText
        g.backgroundColor2 = theme.gutterBackground
        g.highlightActive = highlightCurrentLine
        let lineCount = max(1, (tv.text as NSString).components(separatedBy: "\n").count)
        let digits = max(2, "\(lineCount)".count)
        let sample = String(repeating: "8", count: digits) as NSString
        container.gutterWidth = max(34, sample.size(withAttributes: [.font: g.numberFont]).width + 16)
        context.coordinator.container = container
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyntaxHighlightingEditor
        var isUpdating = false
        weak var container: EditorContainerView?
        var styleSignature = ""

        init(_ parent: SyntaxHighlightingEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            isUpdating = true
            parent.text = textView.text
            parent.onEdit()
            isUpdating = false
            let theme = parent.theme, size = parent.fontSize
            DispatchQueue.main.async { Highlighter.apply(to: textView.textStorage, theme: theme, fontSize: size) }
            container?.gutter.setNeedsDisplay()
            updateCurrentLine()
            reportCaret(textView)
            reportTop(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            container?.gutter.setNeedsDisplay()
            updateCurrentLine()
            reportCaret(textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.gutter.setNeedsDisplay()
            if let tv = container?.textView { reportTop(tv) }
        }

        func reportTop(_ tv: UITextView) {
            let barHeight = container?.gutter.topSkip ?? 0
            let y = max(0, tv.contentOffset.y - tv.textContainerInset.top + barHeight) + 1
            let glyph = tv.layoutManager.glyphIndex(for: CGPoint(x: 2, y: y), in: tv.textContainer)
            let idx = tv.layoutManager.characterIndexForGlyph(at: glyph)
            updateGutterTopSkip(topCharIndex: idx)
            guard parent.topVisibleIndex != idx else { return }
            let binding = parent.$topVisibleIndex
            DispatchQueue.main.async { binding.wrappedValue = idx }
        }

        func updateGutterTopSkip(topCharIndex: Int) {
            guard let g = container?.gutter, let tv = container?.textView else { return }
            if EditorSettings.shared.stickyHeadings {
                let text = tv.text ?? ""
                let stack = stickyStack(parseHeadings(text), upTo: lineStart(in: text, at: topCharIndex))
                let count = min(stack.count, 4)
                g.topSkip = count > 0 ? CGFloat(count) * (parent.fontSize * 1.7) + 1 : 0
            } else {
                g.topSkip = 0
            }
            g.topSkipColor = parent.theme.background
            g.setNeedsDisplay()
        }

        func updateCurrentLine() {
            guard let container, let tv = container.textView as UITextView? else { return }
            guard parent.highlightCurrentLine else { container.currentLineView.isHidden = true; return }
            container.currentLineView.isHidden = false
            let ns = tv.text as NSString
            let caret = min(tv.selectedRange.location, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let glyphRange = tv.layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var r = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            r.origin.x = 0
            r.origin.y += tv.textContainerInset.top
            r.size.width = max(tv.contentSize.width, tv.bounds.width)
            if r.height < 1 { r.size.height = tv.font?.lineHeight ?? 18 }
            container.currentLineView.frame = r
        }

        private func reportCaret(_ tv: UITextView) {
            let pos = caretPosition(in: tv.text, location: tv.selectedRange.location)
            guard parent.caret != pos else { return }
            let binding = parent.$caret
            DispatchQueue.main.async { binding.wrappedValue = pos }
        }

        func performAction(_ action: EditorAction) {
            guard let tv = container?.textView else { return }
            let edit = markdownEdit(action, text: tv.text, selection: tv.selectedRange)
            if let start = tv.position(from: tv.beginningOfDocument, offset: edit.range.location),
               let end = tv.position(from: start, offset: edit.range.length),
               let tr = tv.textRange(from: start, to: end) {
                tv.replace(tr, withText: edit.replacement)
            }
            tv.selectedRange = edit.selection
            parent.text = tv.text
            parent.onEdit()
            Highlighter.apply(to: tv.textStorage, theme: parent.theme, fontSize: parent.fontSize)
            container?.gutter.setNeedsDisplay()
            updateCurrentLine()
            reportCaret(tv)
        }

        func scrollTo(_ index: Int, topInset: CGFloat) {
            guard let tv = container?.textView else { return }
            let ns = tv.text as NSString
            let loc = min(max(index, 0), ns.length)
            tv.selectedRange = NSRange(location: loc, length: 0)
            let glyphRange = tv.layoutManager.glyphRange(forCharacterRange: NSRange(location: loc, length: 0),
                                                         actualCharacterRange: nil)
            var rect = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            rect.origin.y += tv.textContainerInset.top
            let maxY = max(0, tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(CGPoint(x: 0, y: max(0, min(rect.origin.y - topInset, maxY))), animated: true)
            container?.gutter.setNeedsDisplay()
        }

        func performFind(_ tag: Int) {
            guard let tv = container?.textView else { return }
            tv.becomeFirstResponder()
            tv.findInteraction?.presentFindNavigator(showingReplace: tag == 12)
        }

        func revealRange(_ range: NSRange) {
            guard let tv = container?.textView else { return }
            let len = (tv.text as NSString).length
            let loc = min(range.location, len)
            tv.selectedRange = NSRange(location: loc, length: min(range.length, len - loc))
            tv.scrollRangeToVisible(tv.selectedRange)
        }
    }
}

#endif
