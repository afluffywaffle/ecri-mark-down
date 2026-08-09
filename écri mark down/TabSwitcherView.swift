#if !os(macOS)
import SwiftUI

/// Safari-style tab overview for iOS/iPadOS. Opened from the toolbar's tabs button
/// (or the title). Lists every open document; tap to switch, swipe left to close,
/// "New Tab" to add. Closing a modified tab routes through ContentView's guard.
struct TabSwitcherView: View {
    var store: EditorStore
    var onClose: (Document) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.documents) { doc in
                    row(doc)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { onClose(doc) } label: {
                                Label("Close", systemImage: "xmark")
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.newDocument()
                        dismiss()
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ doc: Document) -> some View {
        Button {
            store.selectedID = doc.id
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: doc.fileURL == nil ? "doc" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.displayTitle)
                        .lineLimit(1)
                        .fontWeight(store.selectedID == doc.id ? .semibold : .regular)
                    Text(doc.fileURL == nil ? "Untitled" : doc.fileURL!.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if doc.isModified {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

#endif
