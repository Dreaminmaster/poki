import SwiftUI

struct AutoUnlockSection: View {
    let setting: AutoUnlock
    let canEnable: Bool
    @Binding var showsPasscode: Bool

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { setting.enabled }, set: change)) {
                SettingsRow(title: "Automatic Unlock", symbol: "lock.open")
            }
            .accessibilityIdentifier("autoUnlock.toggle")
            .disabled(!canEnable && !setting.enabled)
            if canEnable && setting.enabled {
                Button("Update Passcode") { showsPasscode = true }
            }
            if setting.deletionFailed {
                Button("Delete Saved Passcode", role: .destructive) { change(false) }
                    .accessibilityIdentifier("autoUnlock.retryDelete")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Poki stores your passcode on this iPhone to unlock it for tasks you start in Poki. Turning this off deletes the passcode.")
                Text("After restarting your iPhone, unlock it once yourself before Poki can unlock it automatically.")
                if setting.deletionFailed {
                    Text("Poki couldn’t delete the saved passcode. Try again to turn off Automatic Unlock.")
                }
                if setting.needsPasscode && setting.enabled {
                    Text("Poki could not confirm the unlock. Unlock your iPhone manually and check your saved passcode.")
                }
            }
            .settingsFooter()
        }
    }

    private func change(_ on: Bool) {
        if on {
            showsPasscode = true
        } else {
            try? setting.disable()
        }
    }
}

struct AutoUnlockPasscodeForm: View {
    let setting: AutoUnlock
    @Environment(\.dismiss) private var dismiss
    @State private var passcode = ""
    @State private var showsStorageError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("iPhone Passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("autoUnlock.passcode")
                } footer: {
                    Text("Enter your 4- or 6-digit iPhone passcode. Poki uses it only on the lock screen.")
                }
            }
            .navigationTitle("Automatic Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!AutoUnlock.accepts(passcode))
                        .accessibilityIdentifier("autoUnlock.save")
                }
            }
            .alert("Could Not Save Passcode", isPresented: $showsStorageError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func save() {
        do {
            try setting.save(passcode)
            passcode = ""
            dismiss()
        } catch {
            showsStorageError = true
        }
    }
}
