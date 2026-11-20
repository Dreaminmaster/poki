import SwiftUI
import PokiCore

/// Screen History Settings: what the collected history is used for (SensesUse).
struct SensesUseSection: View {
    @ObservedObject private var use = SensesUse.shared

    var body: some View {
        Section {
            Toggle("Learn Habits", isOn: $use.learnHabits)
            Toggle("Suggestions on Home", isOn: $use.suggests)
            Toggle("Poki Can Ask Screen History", isOn: $use.agentAsks)
            Picker("Insights Model", selection: $use.insightModel) {
                Text("On This iPhone").tag(SensesInsightModel.onDevice)
                Text("Chat Model").tag(SensesInsightModel.chat)
            }
        } header: {
            Group {
                SettingsHeader("Use History")
            }
            .settingsHeader()
        } footer: {
            Group {
                Text(LocalizedStringKey(use.insightModel == .onDevice
                    ? "Poki learns your usual apps and routines from which apps you use and when, suggests pills for the time of day, and answers Poki's questions about you. A model on this iPhone checks each answer, and asks you first when it is private. Your screen text never leaves this iPhone."
                    : "Poki learns your usual apps and routines from which apps you use and when. Interests and pill ideas are written by your chat model, which then reads your summaries and screen titles. A model on this iPhone still checks each answer for Poki's chat, and asks you first when it is private."))
            }
            .settingsFooter()
        }
    }
}

/// The Memory page's provisional memories from Screen History, apart from notes. Forget, or save one
/// as a note in the owner's own name.
struct SensesMemorySection: View {
    /// Told after one is saved as a note, so the page's notes list shows it.
    var saved: () -> Void = {}
    @ObservedObject private var use = SensesUse.shared
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared
    @ObservedObject private var memories = SensesMemories.shared

    var body: some View {
        if use.learning {
            Section {
                if lock.unlocked || lock.needsSetup {
                    SensesMemoryRows(saved: saved)
                } else {
                    NavigationLink {
                        HistoryGate {
                            Form { SensesMemoryRows(saved: saved) }
                                .navigationTitle(AppLocalization.text("Learned from Screen History"))
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    } label: {
                        SettingsRow(title: "Unlock to View", symbol: "lock")
                    }
                    .accessibilityIdentifier("memory.senses.unlock")
                }
            } header: {
                Group {
                    SettingsHeader("Learned from Screen History")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Inferred on this iPhone from your Screen History. They are not notes. They are not exported or backed up, and agents get them only through a check on this iPhone. Swipe to forget one or save it as a note.")
                }
                .settingsFooter()
            }
            .task { await memories.refresh(force: true) }
        }
    }
}

private struct SensesMemoryRows: View {
    var saved: () -> Void
    @ObservedObject private var memories = SensesMemories.shared

    var body: some View {
        let all = memories.memories
        if all.isEmpty {
            Text("Nothing Learned Yet").foregroundStyle(.secondary)
        }
        ForEach(all) { memory in
            HStack(spacing: 12) {
                if let app = memory.app {
                    AppIconView(app: app, size: 28)
                } else {
                    Image(systemName: "sparkles").frame(width: 28, height: 28).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: memory.text)
                    if !memory.detail.isEmpty {
                        Text(verbatim: memory.detail).font(.allo(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            .swipeActions {
                Button("Forget", role: .destructive) { memories.forget(memory.id) }
                Button("Save as Note") { memories.saveAsNote(memory); saved() }
            }
            .accessibilityIdentifier("memory.senses.\(memory.id)")
        }
    }
}
