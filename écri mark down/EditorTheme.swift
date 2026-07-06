import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

// MARK: - Color helpers

extension PlatformColor {
    /// sRGB color from 0–255 components.
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> PlatformColor {
        #if os(macOS)
        return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        #else
        return UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
        #endif
    }
}

extension Color {
    init(platform: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platform)
        #else
        self.init(uiColor: platform)
        #endif
    }
}

// MARK: - Palette

/// A full set of legibility-tuned colors for one theme.
struct Palette {
    let background, foreground: PlatformColor
    let gutterBackground, gutterText, gutterActiveText, currentLine: PlatformColor
    let heading, emphasisMuted, codeBlock, inlineCode, quote, link, listMarker, strike: PlatformColor
}

// MARK: - Editor theme

/// Curated, legibility-first editor palettes. `system` follows the OS; the rest are
/// fixed. The paper moods (parchment / sepia / dusk / sage / night) echo the sibling
/// `écri` app; light / dark are VS Code-inspired.
enum EditorTheme: String, CaseIterable, Identifiable {
    case system, light, dark, parchment, sepia, dusk, sage, night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:    return "System"
        case .light:     return "Light"
        case .dark:      return "Dark"
        case .parchment: return "Parchment"
        case .sepia:     return "Sepia"
        case .dusk:      return "Dusk"
        case .sage:      return "Sage"
        case .night:     return "Night"
        }
    }

    var isDark: Bool { self == .dark || self == .night }

    // MARK: Palette per theme

    var palette: Palette {
        switch self {
        case .system:
            return Self.systemPalette

        case .light:
            return Palette(
                background: .rgb(255, 255, 255), foreground: .rgb(36, 41, 46),
                gutterBackground: .rgb(246, 248, 250), gutterText: .rgb(150, 152, 154),
                gutterActiveText: .rgb(36, 41, 46), currentLine: .rgb(0, 0, 0, 0.045),
                heading: .rgb(4, 81, 165), emphasisMuted: .rgb(110, 110, 110),
                codeBlock: .rgb(32, 120, 64), inlineCode: .rgb(163, 21, 21),
                quote: .rgb(96, 139, 78), link: .rgb(4, 81, 165),
                listMarker: .rgb(149, 94, 38), strike: .rgb(120, 120, 120))

        case .dark:
            return Palette(
                background: .rgb(30, 30, 30), foreground: .rgb(212, 212, 212),
                gutterBackground: .rgb(30, 30, 30), gutterText: .rgb(110, 110, 110),
                gutterActiveText: .rgb(205, 205, 205), currentLine: .rgb(255, 255, 255, 0.05),
                heading: .rgb(86, 156, 214), emphasisMuted: .rgb(158, 158, 158),
                codeBlock: .rgb(152, 195, 121), inlineCode: .rgb(206, 145, 120),
                quote: .rgb(106, 153, 85), link: .rgb(86, 156, 214),
                listMarker: .rgb(215, 186, 125), strike: .rgb(130, 130, 130))

        case .parchment:
            return Palette(
                background: .rgb(245, 237, 219), foreground: .rgb(58, 46, 30),
                gutterBackground: .rgb(238, 229, 209), gutterText: .rgb(155, 140, 110),
                gutterActiveText: .rgb(58, 46, 30), currentLine: .rgb(95, 72, 40, 0.07),
                heading: .rgb(150, 74, 32), emphasisMuted: .rgb(120, 100, 74),
                codeBlock: .rgb(74, 104, 58), inlineCode: .rgb(168, 74, 42),
                quote: .rgb(128, 110, 82), link: .rgb(36, 96, 150),
                listMarker: .rgb(170, 96, 44), strike: .rgb(140, 122, 96))

        case .sepia:
            return Palette(
                background: .rgb(247, 243, 234), foreground: .rgb(52, 46, 38),
                gutterBackground: .rgb(241, 236, 225), gutterText: .rgb(162, 152, 138),
                gutterActiveText: .rgb(52, 46, 38), currentLine: .rgb(0, 0, 0, 0.045),
                heading: .rgb(150, 70, 54), emphasisMuted: .rgb(120, 108, 92),
                codeBlock: .rgb(56, 110, 72), inlineCode: .rgb(166, 64, 52),
                quote: .rgb(120, 116, 96), link: .rgb(40, 92, 150),
                listMarker: .rgb(156, 98, 50), strike: .rgb(135, 122, 104))

        case .dusk:
            return Palette(
                background: .rgb(238, 238, 246), foreground: .rgb(48, 46, 60),
                gutterBackground: .rgb(231, 231, 242), gutterText: .rgb(150, 148, 168),
                gutterActiveText: .rgb(48, 46, 60), currentLine: .rgb(40, 40, 80, 0.06),
                heading: .rgb(84, 76, 168), emphasisMuted: .rgb(108, 104, 128),
                codeBlock: .rgb(48, 108, 96), inlineCode: .rgb(168, 72, 120),
                quote: .rgb(110, 106, 140), link: .rgb(74, 84, 184),
                listMarker: .rgb(140, 96, 150), strike: .rgb(128, 124, 148))

        case .sage:
            return Palette(
                background: .rgb(236, 242, 232), foreground: .rgb(44, 54, 42),
                gutterBackground: .rgb(229, 236, 224), gutterText: .rgb(146, 158, 140),
                gutterActiveText: .rgb(44, 54, 42), currentLine: .rgb(40, 70, 40, 0.06),
                heading: .rgb(40, 100, 64), emphasisMuted: .rgb(104, 116, 100),
                codeBlock: .rgb(120, 92, 36), inlineCode: .rgb(168, 84, 52),
                quote: .rgb(100, 120, 96), link: .rgb(44, 100, 120),
                listMarker: .rgb(150, 110, 50), strike: .rgb(120, 128, 116))

        case .night:
            return Palette(
                background: .rgb(34, 30, 26), foreground: .rgb(224, 214, 196),
                gutterBackground: .rgb(34, 30, 26), gutterText: .rgb(120, 110, 96),
                gutterActiveText: .rgb(224, 214, 196), currentLine: .rgb(255, 240, 210, 0.05),
                heading: .rgb(226, 170, 110), emphasisMuted: .rgb(176, 166, 150),
                codeBlock: .rgb(168, 190, 130), inlineCode: .rgb(224, 158, 120),
                quote: .rgb(150, 140, 120), link: .rgb(150, 190, 224),
                listMarker: .rgb(216, 188, 140), strike: .rgb(150, 140, 124))
        }
    }

    private static var systemPalette: Palette {
        #if os(macOS)
        return Palette(
            background: .textBackgroundColor, foreground: .labelColor,
            gutterBackground: .textBackgroundColor, gutterText: .tertiaryLabelColor,
            gutterActiveText: .labelColor, currentLine: NSColor.labelColor.withAlphaComponent(0.06),
            heading: .systemBlue, emphasisMuted: .secondaryLabelColor,
            codeBlock: .systemGreen, inlineCode: .systemOrange,
            quote: .systemGray, link: .systemBlue,
            listMarker: .systemOrange, strike: .systemGray)
        #else
        return Palette(
            background: .systemBackground, foreground: .label,
            gutterBackground: .secondarySystemBackground, gutterText: .tertiaryLabel,
            gutterActiveText: .label, currentLine: UIColor.label.withAlphaComponent(0.06),
            heading: .systemBlue, emphasisMuted: .secondaryLabel,
            codeBlock: .systemGreen, inlineCode: .systemOrange,
            quote: .systemGray, link: .systemBlue,
            listMarker: .systemOrange, strike: .systemGray)
        #endif
    }

    // MARK: Role accessors

    var background: PlatformColor { palette.background }
    var foreground: PlatformColor { palette.foreground }
    var gutterBackground: PlatformColor { palette.gutterBackground }
    var gutterText: PlatformColor { palette.gutterText }
    var gutterActiveText: PlatformColor { palette.gutterActiveText }
    var currentLine: PlatformColor { palette.currentLine }
    var heading: PlatformColor { palette.heading }
    var emphasisMuted: PlatformColor { palette.emphasisMuted }
    var codeBlock: PlatformColor { palette.codeBlock }
    var inlineCode: PlatformColor { palette.inlineCode }
    var quote: PlatformColor { palette.quote }
    var link: PlatformColor { palette.link }
    var listMarker: PlatformColor { palette.listMarker }
    var strike: PlatformColor { palette.strike }

    // MARK: SwiftUI convenience

    var backgroundColor: Color { Color(platform: background) }
    var foregroundColor: Color { Color(platform: foreground) }
    var swatch: Color { Color(platform: background) }
}
