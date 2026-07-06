import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = EditorSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(EditorTheme.allCases) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Editor") {
                Toggle("Line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Sticky headings while scrolling", isOn: $settings.stickyHeadings)
                if settings.stickyHeadings {
                    Picker("Sticky heading click", selection: $settings.stickyPrimaryAction) {
                        ForEach(StickyClickAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    Text("The other action is available on ⌘-click or right-click.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Status bar", isOn: $settings.showStatusBar)
                Toggle("Formatting toolbar (authoring)", isOn: $settings.formattingToolsEnabled)
                Stepper(value: $settings.fontSize,
                        in: EditorSettings.minFontSize...EditorSettings.maxFontSize,
                        step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Saving") {
                Toggle("Autosave", isOn: $settings.autosave)
                Text("Autosave writes changes to disk automatically for files that already have a location. A new document still needs one Save to choose where it lives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Windows") {
                Picker("Open documents in", selection: $settings.openInNewWindow) {
                    Text("A new tab").tag(false)
                    Text("A new window").tag(true)
                }
                Text("New windows are independent sessions with their own tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                Toggle("Serif preview font", isOn: $settings.useSerifPreview)
            }

            Section {
                Button("Ultraminimal") { settings.resetToUltraminimal() }
                    .help("Turn off line numbers, current-line highlight, and the status bar, and use the system theme.")
            } footer: {
                Text("A one-tap plain-source look: no gutter, no current-line, no status bar, system colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 400, height: 500)
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .navigationTitle("Settings")
        #endif
    }

    private func themeSwatch(_ theme: EditorTheme) -> some View {
        let selected = settings.theme == theme
        return VStack(spacing: 6) {
            Button { settings.theme = theme } label: {
                Circle()
                    .fill(theme.swatch)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.foregroundColor)
                        }
                    }
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
            }
            .buttonStyle(.plain)
            Text(theme.displayName).font(.caption)
        }
    }
}

#Preview {
    SettingsView()
}
