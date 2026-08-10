//
//  ScratchpadIntents.swift
//  écri mark down
//
//  Created by Jayrom Acorda on 8/9/26.
//

// These Siri/Shortcuts/Spotlight actions funnel through the `ecrimarkdown://`
// URL scheme handled in `e_cri_mark_downApp.swift` (see `.onOpenURL`), so every
// external surface reduces to one of the two deep-link primitives.

import AppIntents
import Foundation
import SwiftUI

/// Opens the scratchpad.
struct OpenScratchpadIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Scratchpad"
    static let description = IntentDescription("Opens your scratchpad.")

    func perform() async throws -> some IntentResult {
        try await EnvironmentValues().openURL(URL(string: "ecrimarkdown://scratchpad")!)
        return .result()
    }
}

/// Starts a new scratchpad.
struct NewScratchpadIntent: AppIntent {
    static let title: LocalizedStringResource = "New Scratchpad"
    static let description = IntentDescription("Starts a new scratchpad.")

    func perform() async throws -> some IntentResult {
        try await EnvironmentValues().openURL(URL(string: "ecrimarkdown://new")!)
        return .result()
    }
}

/// Surfaces the scratchpad actions to Siri / Shortcuts / Spotlight.
///
/// The `appintentsmetadataprocessor` requires EVERY utterance to contain the
/// `${applicationName}` substitution, so each phrase carries the app name — that
/// is also how Siri disambiguates this shortcut from other apps'.
struct ScratchpadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenScratchpadIntent(),
                    phrases: [
                        "Open \(.applicationName)",
                        "Open my scratchpad in \(.applicationName)",
                        "Go to my scratchpad in \(.applicationName)",
                    ])
        AppShortcut(intent: NewScratchpadIntent(),
                    phrases: [
                        "New \(.applicationName)",
                        "Start a new scratchpad in \(.applicationName)",
                        "Make a new scratchpad in \(.applicationName)",
                    ])
    }
}
