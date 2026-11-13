import SwiftUI

/// A home page pill's Edit page (long press, Edit): its sentence and its app, in the form the model
/// key page uses (`KeyEntry`). Beginning the sentence with an app's name picks that app; taking the
/// app's name out of a sentence that began with it leaves no app, and the pill shows Poki's icon.
struct ShortcutEditor: View {
    var shortcut: HomeShortcut
    var save: (_ sentence: String, _ app: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sentence: String
    /// A bundle ID, or empty for none.
    @State private var app: String

    init(shortcut: HomeShortcut, save: @escaping (_ sentence: String, _ app: String?) -> Void) {
        self.shortcut = shortcut
        self.save = save
        _sentence = State(initialValue: shortcut.prompt)
        _app = State(initialValue: shortcut.app)
    }

    /// Every app Poki knows by name, by its name on this iPhone.
    private static var apps: [(id: String, name: String)] {
        KnownApps.all.map { ($0.id, $0.name(in: .current)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What Poki should do", text: $sentence, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("A tap puts this in the message field. Begin it with an app’s name to use that app.")
                }
                Section {
                    Picker("App", selection: $app) {
                        Label { Text("None") } icon: { DefaultAppIcon(size: 24) }.tag("")
                        ForEach(Self.apps, id: \.id) { known in
                            Label { Text(verbatim: known.name) } icon: { AppIconView(app: known.id, size: 24, alwaysLight: true) }
                                .tag(known.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("With no app, the shortcut shows Poki’s icon.")
                }
            }
            .navigationTitle("Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(sentence, app.isEmpty ? nil : app)
                        dismiss()
                    }
                    .disabled(sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: sentence) { old, new in
                app = ShortcutApp.following(new, was: old, app: app.isEmpty ? nil : app) ?? ""
            }
        }
    }
}
