import AppIntents
import SwiftUI
import WidgetKit

struct ScratchpadControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "ScratchpadControl",
            content: {
                ControlWidgetButton(action: ScratchpadOpenIntent()) {
                    Label("Scratchpad", systemImage: "square.and.pencil")
                }
            }
        )
    }
}
