#if os(macOS)
import SwiftUI
import Observation

/// Drives the outline sidebar — mirrors FindModel's shape so ContentView can host it
/// the same way it hosts Find.
@Observable
final class OutlineModel {
    static let shared = OutlineModel()

    var isOpen = false
    /// Heading levels currently shown (1...6). Empty means "no filter" — show all.
    var activeLevels: Set<Int> = [1, 2, 3, 4, 5, 6]
    /// Bumped each time Outline is invoked so the sidebar re-focuses even if already open.
    @ObservationIgnored var openToken = 0

    func open() {
        openToken += 1
        isOpen = true
    }

    func toggle() {
        isOpen.toggle()
        if isOpen { openToken += 1 }
    }

    func toggleLevel(_ level: Int) {
        if activeLevels.contains(level) {
            activeLevels.remove(level)
        } else {
            activeLevels.insert(level)
        }
    }

    func showAll() { activeLevels = [1, 2, 3, 4, 5, 6] }
}

struct OutlineSidebar: View {
    var text: String
    @State private var model = OutlineModel.shared

    private var allHeadings: [MDHeading] { parseHeadings(text) }
    private var filtered: [MDHeading] { allHeadings.filter { model.activeLevels.contains($0.level) } }
    private var levelsPresent: [Int] {
        Array(Set(allHeadings.map(\.level))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 240)
        .background(.bar)
        .onExitCommand { model.isOpen = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Outline")
                    .font(.headline)
                Spacer()
                Button { model.isOpen = false } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain).help("Close (⎋)")
            }
            if !levelsPresent.isEmpty {
                HStack(spacing: 4) {
                    ForEach(levelsPresent, id: \.self) { level in
                        levelChip(level)
                    }
                    Spacer(minLength: 0)
                    if model.activeLevels.count < 6 {
                        Button("All") { model.showAll() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
    }

    private func levelChip(_ level: Int) -> some View {
        let isOn = model.activeLevels.contains(level)
        return Button("H\(level)") { model.toggleLevel(level) }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .help("Filter to headings level \(level)")
    }

    @ViewBuilder
    private var content: some View {
        if allHeadings.isEmpty {
            placeholder("No headings in this document")
        } else if filtered.isEmpty {
            placeholder("No headings at the selected level")
        } else {
            List {
                ForEach(filtered) { h in
                    row(h)
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ h: MDHeading) -> some View {
        Button {
            let inset = CGFloat(min(h.level - 1, 4)) * 0
            EditorActionBus.shared.scroll(to: h.charIndex, topInset: inset)
        } label: {
            HStack(spacing: 6) {
                Text("H\(h.level)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
                Text(h.text.isEmpty ? "(untitled)" : h.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(h.level - 1) * 10)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
