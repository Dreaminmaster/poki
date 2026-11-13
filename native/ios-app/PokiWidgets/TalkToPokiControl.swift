import AppIntents
import SwiftUI
import WidgetKit

/// Talk to Poki as a control: in Control Center, on the Lock Screen and under the Action Button's
/// Controls. It runs TalkToPokiIntent, which opens Poki.
struct TalkToPokiControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PokiTalk") {
            ControlWidgetButton(action: TalkToPokiIntent()) {
                Label(String(localized: "Talk to Poki", table: "Entry"), systemImage: "waveform.circle")
            }
        }
        .displayName(LocalizedStringResource("Talk to Poki", table: "Entry"))
        .description(LocalizedStringResource("Opens Poki and starts talking.", table: "Entry"))
    }
}
