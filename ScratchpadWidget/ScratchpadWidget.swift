import SwiftUI
import WidgetKit

// Launcher-only today: when the CloudKit sync store lands, this becomes an
// AppIntentTimelineProvider showing the current pad (title/content).
struct ScratchpadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScratchpadLauncher", provider: Provider()) { _ in
            ScratchpadWidgetView()
        }
        .configurationDisplayName("Scratchpad")
        .description("Opens your scratchpad.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ScratchpadEntry: TimelineEntry {
    let date: Date
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ScratchpadEntry { ScratchpadEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ScratchpadEntry) -> Void) {
        completion(ScratchpadEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScratchpadEntry>) -> Void) {
        completion(Timeline(entries: [ScratchpadEntry(date: Date())], policy: .never))
    }
}

struct ScratchpadWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private var scratchpadURL: URL { URL(string: "ecrimarkdown://scratchpad")! }

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack {
                    Link(destination: scratchpadURL) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "square.and.pencil")
                                .font(.title2)
                            Text("Scratchpad")
                                .font(.headline)
                            Text("Tap to open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(intent: ScratchpadNewIntent()) {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Link(destination: scratchpadURL) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.title2)
                        Text("Scratchpad")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
