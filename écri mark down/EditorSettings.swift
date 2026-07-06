import SwiftUI
import Observation

// MARK: - Caret position (for the status bar)

struct CaretPosition: Equatable {
    var line = 1
    var column = 1
}

/// What a plain click on a sticky heading does. The other action is available on
/// ⌥-click and right-click.
enum StickyClickAction: String, CaseIterable, Identifiable {
    case jump      // scroll to that section
    case outline   // dropdown of sibling headings to jump between

    var id: String { rawValue }
    var label: String {
        switch self {
        case .jump:    return "Jump to section"
        case .outline: return "Show outline"
        }
    }
}

// MARK: - Editor settings

/// Single source of truth for editor appearance/behavior. Each property persists to
/// `UserDefaults` in its `didSet`, and SwiftUI views observe it via `@Observable`.
/// Mirrors the `AppSettings` singleton pattern from the sibling `écri` app.
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    // Sensible "looks like VS Code" defaults so first launch reads correctly.
    static let defaultFontSize: CGFloat = {
        #if os(macOS)
        return 13
        #else
        return 15
        #endif
    }()

    static let minFontSize: CGFloat = 9
    static let maxFontSize: CGFloat = 28

    var theme: EditorTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }
    var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: Keys.showLineNumbers) }
    }
    var highlightCurrentLine: Bool {
        didSet { UserDefaults.standard.set(highlightCurrentLine, forKey: Keys.highlightCurrentLine) }
    }
    var showStatusBar: Bool {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: Keys.showStatusBar) }
    }
    /// VS Code-style "sticky scroll": pin the enclosing heading(s) to the top while scrolling.
    var stickyHeadings: Bool {
        didSet { UserDefaults.standard.set(stickyHeadings, forKey: Keys.stickyHeadings) }
    }
    /// Show the authoring/formatting toolbar (Bold, Italic, …). Off by default so the
    /// review-first experience stays clean; its keyboard shortcuts are only active when shown.
    var formattingToolsEnabled: Bool {
        didSet { UserDefaults.standard.set(formattingToolsEnabled, forKey: Keys.formattingTools) }
    }
    /// Plain-click behavior on a sticky heading (the other is on ⌥-click / right-click).
    var stickyPrimaryAction: StickyClickAction {
        didSet { UserDefaults.standard.set(stickyPrimaryAction.rawValue, forKey: Keys.stickyPrimary) }
    }
    var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: Keys.fontSize) }
    }
    var useSerifPreview: Bool {
        didSet { UserDefaults.standard.set(useSerifPreview, forKey: Keys.useSerifPreview) }
    }
    /// Live autosave for documents that already have a file location. Default on.
    var autosave: Bool {
        didSet { UserDefaults.standard.set(autosave, forKey: Keys.autosave) }
    }
    /// Open documents in a new window (each its own session) instead of a new tab.
    var openInNewWindow: Bool {
        didSet { UserDefaults.standard.set(openInNewWindow, forKey: Keys.openInNewWindow) }
    }

    private init() {
        let d = UserDefaults.standard
        theme = EditorTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        showLineNumbers = d.object(forKey: Keys.showLineNumbers) as? Bool ?? true
        highlightCurrentLine = d.object(forKey: Keys.highlightCurrentLine) as? Bool ?? true
        showStatusBar = d.object(forKey: Keys.showStatusBar) as? Bool ?? true
        stickyHeadings = d.object(forKey: Keys.stickyHeadings) as? Bool ?? true
        formattingToolsEnabled = d.object(forKey: Keys.formattingTools) as? Bool ?? false
        stickyPrimaryAction = StickyClickAction(rawValue: d.string(forKey: Keys.stickyPrimary) ?? "") ?? .jump
        let storedSize = d.object(forKey: Keys.fontSize) as? Double
        fontSize = storedSize.map { CGFloat($0) } ?? Self.defaultFontSize
        useSerifPreview = d.object(forKey: Keys.useSerifPreview) as? Bool ?? false
        autosave = d.object(forKey: Keys.autosave) as? Bool ?? true
        openInNewWindow = d.object(forKey: Keys.openInNewWindow) as? Bool ?? false
    }

    func increaseFontSize() { fontSize = min(Self.maxFontSize, (fontSize + 1).rounded()) }
    func decreaseFontSize() { fontSize = max(Self.minFontSize, (fontSize - 1).rounded()) }
    func resetFontSize() { fontSize = Self.defaultFontSize }

    func resetToUltraminimal() {
        theme = .system
        showLineNumbers = false
        highlightCurrentLine = false
        showStatusBar = false
        stickyHeadings = false
    }

    private enum Keys {
        static let theme = "editor.theme"
        static let showLineNumbers = "editor.showLineNumbers"
        static let highlightCurrentLine = "editor.highlightCurrentLine"
        static let showStatusBar = "editor.showStatusBar"
        static let stickyHeadings = "editor.stickyHeadings"
        static let formattingTools = "editor.formattingTools"
        static let stickyPrimary = "editor.stickyPrimary"
        static let fontSize = "editor.fontSize"
        static let useSerifPreview = "editor.useSerifPreview"
        static let autosave = "editor.autosave"
        static let openInNewWindow = "editor.openInNewWindow"
    }
}
