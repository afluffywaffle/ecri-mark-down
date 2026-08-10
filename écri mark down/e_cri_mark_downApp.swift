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
#if !os(macOS)
import UIKit
#endif

@main
struct e_cri_mark_downApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup(for: PendingOpen.self) { $pending in
            ContentView(pending: pending)
                .onOpenURL { url in
                    if url.scheme?.lowercased() == "ecrimarkdown" {
                        WindowRouter.shared.openScratchpad(url)
                    } else {
                        WindowRouter.shared.openFile(url: url)
                    }
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
        urls.forEach { WindowRouter.shared.openFile(url: $0) }
    }

    /// Guard against quitting with unsaved changes across all windows.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = WindowRouter.shared.unsavedPairs()
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
            for (store, doc) in unsaved {
                store.selectedID = doc.id
                store.saveSelected()
            }
            return WindowRouter.shared.hasUnsavedChanges() ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
#endif

#if !os(macOS)
final class iOSAppDelegate: NSObject, UIApplicationDelegate {
    /// Home-screen quick actions: both funnel through the `ecrimarkdown://` URL
    /// scheme so the app handles them in the one place (see `.onOpenURL`).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "openScratchpad",
                localizedTitle: "Open Scratchpad",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"),
                userInfo: ["url": "ecrimarkdown://scratchpad" as NSString]
            ),
            UIApplicationShortcutItem(
                type: "newScratchpad",
                localizedTitle: "New Scratchpad",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus"),
                userInfo: ["url": "ecrimarkdown://new" as NSString]
            ),
        ]
        return true
    }

    /// Fallback path when the system delivers a quick action instead of opening
    /// the URL. Reads the target URL out of `userInfo` and opens it.
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        if let urlString = shortcutItem.userInfo?["url"] as? String,
           let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        completionHandler(true)
    }
}
#endif

// MARK: - Menu bar commands

struct AppCommands: Commands {
    @AppStorage("viewMode") private var viewModeRaw = ViewMode.source.rawValue
    @FocusedValue(\.editorStore) private var store

    var body: some Commands {
        // Keep the system "New Window" (⌘N) and add "New Tab" beside it.
        CommandGroup(after: .newItem) {
            Button("New Tab") { store?.newDocument() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store == nil)
            #if os(macOS)
            Button("Open…") { WindowRouter.shared.openViaPanel() }
                .keyboardShortcut("o", modifiers: .command)
            RecentsMenu()
            #endif
        }

        #if os(macOS)
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store?.saveSelected() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store == nil)
            Button("Save As…") { store?.saveSelectedAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("Reveal in Finder") {
                if let doc = store?.selectedDocument { store?.revealInFinder(doc) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled((store?.selectedDocument?.fileURL) == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                // Resolve the doc from the focused store, falling back to the active window.
                if let doc = store?.selectedDocument ?? WindowRouter.shared.activeStore?.selectedDocument {
                    MarkdownPrinter.print(doc)
                }
            }
            .keyboardShortcut("p", modifiers: .command)
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
            Divider()
            Button("Show Outline") { OutlineModel.shared.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
                    Button(item.name) { WindowRouter.shared.openRecent(item) }
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
