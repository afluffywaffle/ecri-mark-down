#if os(macOS)
import SwiftUI
import Observation

struct FindMatch: Identifiable {
    let id: Int          // match start location — unique per match
    let range: NSRange   // in the full document
    let line: Int
    let lineText: String
    let inLineRange: NSRange
}

@Observable
final class FindModel {
    static let shared = FindModel()

    var isOpen = false
    var query = ""
    var replaceText = ""
    var caseSensitive = false
    var matches: [FindMatch] = []
    @ObservationIgnored var currentIndex = -1
    /// Bumped each time Find is invoked so the sidebar re-focuses even if already open.
    @ObservationIgnored var openToken = 0
    @ObservationIgnored var focusReplace = false

    func open(replace: Bool = false) {
        focusReplace = replace
        openToken += 1
        isOpen = true
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        EditorActionBus.shared.reveal(matches[currentIndex].range)
    }

    func prev() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        EditorActionBus.shared.reveal(matches[currentIndex].range)
    }

    func replaceCurrent() {
        guard !matches.isEmpty else { return }
        if currentIndex < 0 || currentIndex >= matches.count { currentIndex = 0 }
        EditorActionBus.shared.replace(matches[currentIndex].range, with: replaceText)
        // The edit re-triggers recompute in the sidebar; keep the index roughly in place.
        currentIndex = max(-1, currentIndex - 1)
    }

    func replaceAll() {
        guard !matches.isEmpty else { return }
        EditorActionBus.shared.replaceAll(query: query, with: replaceText, caseSensitive: caseSensitive)
    }
}

/// All matches of `query` with line number and context. Single pass, O(n).
func computeFindMatches(_ text: String, query: String, caseSensitive: Bool) -> [FindMatch] {
    guard !query.isEmpty else { return [] }
    let ns = text as NSString
    let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    var results: [FindMatch] = []
    var start = 0
    var scan = 0
    var line = 1
    while start < ns.length {
        let found = ns.range(of: query, options: opts, range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { break }
        while scan < found.location { if ns.character(at: scan) == 10 { line += 1 }; scan += 1 }
        let lineR = ns.lineRange(for: NSRange(location: found.location, length: 0))
        let lineText = ns.substring(with: lineR).trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
        let inLine = NSRange(location: found.location - lineR.location, length: found.length)
        results.append(FindMatch(id: found.location, range: found, line: line,
                                 lineText: lineText, inLineRange: inLine))
        start = found.location + max(1, found.length)
        if results.count >= 2000 { break }
    }
    return results
}

struct FindSidebar: View {
    var text: String
    @State private var model = FindModel.shared
    @FocusState private var focus: Field?

    enum Field { case find, replace }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 280)
        .background(.bar)
        .onAppear { recompute(); applyFocus() }
        .onChange(of: model.openToken) { _, _ in applyFocus() }
        .onChange(of: model.query) { _, _ in recompute() }
        .onChange(of: model.caseSensitive) { _, _ in recompute() }
        .onChange(of: text) { _, _ in recompute() }
        .onExitCommand { model.isOpen = false }
    }

    private func recompute() {
        model.matches = computeFindMatches(text, query: model.query, caseSensitive: model.caseSensitive)
        model.currentIndex = -1
    }

    private func applyFocus() {
        // Defer so the field exists before we target it.
        DispatchQueue.main.async { focus = model.focusReplace ? .replace : .find }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                fieldBox {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Find", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .find)
                        .onSubmit { model.next() }
                    if !model.query.isEmpty {
                        Text("\(model.matches.count)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button { model.caseSensitive.toggle() } label: {
                    Text("Aa").font(.caption)
                        .fontWeight(model.caseSensitive ? .bold : .regular)
                        .foregroundStyle(model.caseSensitive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain).help("Match case")
                Button { model.isOpen = false } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain).help("Close (⎋)")
            }

            HStack(spacing: 6) {
                fieldBox {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary).font(.caption)
                    TextField("Replace", text: $model.replaceText)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .replace)
                        .onSubmit { model.replaceCurrent() }
                }
                Button("Replace") { model.replaceCurrent() }
                    .font(.caption).disabled(model.matches.isEmpty)
                Button("All") { model.replaceAll() }
                    .font(.caption).disabled(model.matches.isEmpty)
            }
        }
        .padding(8)
    }

    private func fieldBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            placeholder("Type to search the current document")
        } else if model.matches.isEmpty {
            placeholder("No results")
        } else {
            List {
                ForEach(Array(model.matches.enumerated()), id: \.element.id) { idx, m in
                    row(idx, m)
                        .listRowBackground(idx == model.currentIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ idx: Int, _ m: FindMatch) -> some View {
        Button {
            model.currentIndex = idx
            EditorActionBus.shared.reveal(m.range)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Line \(m.line)")
                    .font(.caption2).foregroundStyle(.secondary)
                context(m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func context(_ m: FindMatch) -> some View {
        let lt = m.lineText as NSString
        let loc = min(m.inLineRange.location, lt.length)
        let end = min(loc + m.inLineRange.length, lt.length)
        var before = lt.substring(to: loc)
        let matchStr = lt.substring(with: NSRange(location: loc, length: end - loc))
        let after = lt.substring(from: end)
        if before.count > 24 { before = "…" + String(before.suffix(24)) }
        return (Text(before)
                + Text(matchStr).bold().foregroundColor(.accentColor)
                + Text(after))
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(2)
    }

    private func placeholder(_ s: String) -> some View {
        VStack {
            Spacer()
            Text(s).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
