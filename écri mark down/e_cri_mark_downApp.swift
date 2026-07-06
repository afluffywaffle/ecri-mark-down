//
//  e_cri_mark_downApp.swift
//  écri mark down
//
//  Created by Jayrom Acorda on 6/18/26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct e_cri_mark_downApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in EditorStore.shared.open(url: url) }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter { $0.isFileURL }
                    files.forEach { EditorStore.shared.open(url: $0) }
                    return !files.isEmpty
                }
        }
        .commands { AppCommands() }
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder (double-click / "Open With") or drag-to-Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { EditorStore.shared.open(url: $0) }
    }

    /// Guard against quitting with unsaved changes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = EditorStore.shared.documents.filter { $0.isModified }
        guard !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "You have unsaved changes."
            : "You have \(unsaved.count) documents with unsaved changes."
        alert.informativeText = "Do you want to save them before quitting?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for doc in unsaved {
                EditorStore.shared.selectedID = doc.id
                EditorStore.shared.saveSelected()
            }
            // If an untitled save was cancelled, abort the quit.
            return EditorStore.shared.documents.contains { $0.isModified } ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
#endif

// MARK: - Menu bar commands

struct AppCommands: Commands {
    @AppStorage("viewMode") private var viewModeRaw = ViewMode.source.rawValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { EditorStore.shared.newDocument() }
                .keyboardShortcut("t", modifiers: .command)
            #if os(macOS)
            Button("Open…") { EditorStore.shared.openViaPanel() }
                .keyboardShortcut("o", modifiers: .command)
            RecentsMenu()
            #endif
        }

        #if os(macOS)
        CommandGroup(replacing: .saveItem) {
            Button("Save") { EditorStore.shared.saveSelected() }
                .keyboardShortcut("s", modifiers: .command)
        }
        #endif

        CommandGroup(after: .pasteboard) {
            Divider()
            #if os(macOS)
            Button("Find…") { FindModel.shared.open() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find & Replace…") { FindModel.shared.open(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { FindModel.shared.next() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { FindModel.shared.prev() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            #else
            // iOS uses the system find interaction (tags are NSTextFinder.Action raw values).
            Button("Find…") { EditorActionBus.shared.find(1) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { EditorActionBus.shared.find(2) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { EditorActionBus.shared.find(3) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Find & Replace…") { EditorActionBus.shared.find(12) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            #endif
        }

        // Named "Editor" (not "View") so it doesn't collide with the system-provided
        // View menu (Show Tab Bar / Enter Full Screen).
        CommandMenu("Editor") {
            Button("Source") { viewModeRaw = ViewMode.source.rawValue }
                .keyboardShortcut("1", modifiers: .command)
            Button("Split") { viewModeRaw = ViewMode.split.rawValue }
                .keyboardShortcut("2", modifiers: .command)
            Button("Preview") { viewModeRaw = ViewMode.preview.rawValue }
                .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("Increase Font Size") { EditorSettings.shared.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { EditorSettings.shared.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { EditorSettings.shared.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            ViewToggles()
        }
    }
}

#if os(macOS)
/// The File ▸ Open Recent submenu.
struct RecentsMenu: View {
    @State private var recents = RecentsStore.shared

    var body: some View {
        Menu("Open Recent") {
            if recents.items.isEmpty {
                Text("No Recent Files")
            } else {
                ForEach(recents.items) { item in
                    Button(item.name) { EditorStore.shared.openRecent(item) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
            }
        }
    }
}
#endif

/// Chrome toggles for the View menu (labels reflect current state).
struct ViewToggles: View {
    @State private var settings = EditorSettings.shared

    var body: some View {
        Button(settings.showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers") {
            settings.showLineNumbers.toggle()
        }
        Button(settings.highlightCurrentLine ? "Hide Current-Line Highlight" : "Highlight Current Line") {
            settings.highlightCurrentLine.toggle()
        }
        Button(settings.stickyHeadings ? "Hide Sticky Headings" : "Show Sticky Headings") {
            settings.stickyHeadings.toggle()
        }
        Button(settings.showStatusBar ? "Hide Status Bar" : "Show Status Bar") {
            settings.showStatusBar.toggle()
        }
        Divider()
        Button(settings.formattingToolsEnabled ? "Hide Formatting Toolbar" : "Show Formatting Toolbar") {
            settings.formattingToolsEnabled.toggle()
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}
