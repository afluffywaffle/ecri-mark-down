import SwiftUI

/// How the current document is displayed. Cycles source → split → preview.
enum ViewMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: String { rawValue }

    /// Next mode in the cycle (⌘⇧P advances through these).
    var next: ViewMode {
        switch self {
        case .source:  return .split
        case .split:   return .preview
        case .preview: return .source
        }
    }

    var label: String {
        switch self {
        case .source:  return "Source"
        case .split:   return "Split"
        case .preview: return "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .source:  return "chevron.left.forwardslash.chevron.right"
        case .split:   return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }
}
