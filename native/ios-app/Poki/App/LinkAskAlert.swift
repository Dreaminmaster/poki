import SwiftUI

/// The owner's answer to a `poki://` link that would change the relay or the pairing file
/// (`AppModel.linkAsk`). On the root view, and on the first run's cover, which hides the root's alerts.
struct LinkAskAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    /// False while another presentation of this alert is the one in front.
    var active = true

    private var title: String {
        guard let ask = model.linkAsk else { return "" }
        if case .relay = ask.kind { return AppLocalization.text("Use This Relay?") }
        return AppLocalization.text("Use This Pairing File?")
    }

    func body(content: Content) -> some View {
        // Each answer names the request the alert shows (`AppModel.answerLink(_:to:)`).
        content.alert(title, isPresented: Binding(get: { active && model.linkAsk != nil }, set: { if !$0, let id = model.linkAsk?.id { model.answerLink(false, to: id) } }), presenting: model.linkAsk) { ask in
            Button("Don’t Allow", role: .cancel) { model.answerLink(false, to: ask.id) }
            Button("Allow") { model.answerLink(true, to: ask.id) }
        } message: { ask in
            switch ask.kind {
            case .relay:
                Text("A link asks Poki to connect through \(ask.host). Whoever runs that relay can see your screen and act on this iPhone through Poki. Allow it only if you set up this relay yourself.")
            case .pairingData:
                Text("A link carries a pairing file for Poki. It replaces the pairing this iPhone has now, and automation stops if the file is wrong. Allow it only if you made it yourself in Poki Setup.")
            case .pairingURL:
                Text("A link asks Poki to fetch a pairing file from \(ask.host). It replaces the pairing this iPhone has now, and automation stops if the file is wrong. Allow it only if you made it yourself in Poki Setup.")
            }
        }
    }
}
