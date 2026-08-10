import AppIntents
import Foundation
import SwiftUI

struct ScratchpadNewIntent: AppIntent {
    static let title: LocalizedStringResource = "New Scratchpad"
    func perform() async throws -> some IntentResult {
        try await EnvironmentValues().openURL(URL(string: "ecrimarkdown://new")!)
        return .result()
    }
}
