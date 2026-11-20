import SwiftUI

/// Settings › Models › Voice: where to put Poki on the Action Button, in Control Center and on the Lock Screen.
struct ActionButtonSection: View {
    var body: some View {
        Section {
            Label {
                Text("Settings › Action Button › Shortcut › Poki Anytime", tableName: "Entry")
            } icon: {
                Image(systemName: "button.programmable")
            }
        } header: {
            Text("Action Button", tableName: "Entry")
        } footer: {
            Group {
                Text("Press and hold the Action button to talk with Poki without leaving the app you’re in. Press and hold it again to end the talk. To open Poki and talk there instead, choose Controls, then Talk to Poki. To type a task, choose Shortcut, then Send Task. Control Center and the Lock Screen can hold Talk to Poki too.", tableName: "Entry")
            }
            .settingsFooter()
        }
    }
}
