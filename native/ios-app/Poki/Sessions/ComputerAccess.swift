import Foundation
import Observation
import PokiCore
import SwiftUI

/// Agents › Computers (the owner, Nov 21 2026): the computers running Poki MCP (bundled in Poki Setup)
/// that came to this iPhone, each allowed or turned off by the owner. A computer is known by its key's
/// fingerprint from its hello (issue #609), so turning one off leaves every other computer and every
/// relay agent as it was. A computer seen for the first time is refused until it is allowed here.
@MainActor
@Observable
final class ComputerAccess {
    static let shared = ComputerAccess()

    struct Known: Codable, Identifiable, Equatable {
        var computer: ClientComputer
        /// The owner's word: true allowed, false turned off, nil not answered yet.
        var allowed: Bool?
        var firstSeen: Date
        var lastSeen: Date
        var id: String { computer.id }
    }

    private(set) var computers: [Known] = []
    private static let listKey = "computers.list"
    /// The owner's answers alone, by fingerprint, for PokiCore to read at each call from any thread.
    nonisolated private static let accessKey = "computers.access"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([Known].self, from: data) {
            computers = list
        }
    }

    /// PokiCore's question at each call: true, false, or nil for a computer the owner has not answered.
    nonisolated static func decision(_ id: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: accessKey) as? [String: Bool])?[id]
    }

    /// A session came from this computer: it is listed, new ones waiting for the owner's answer.
    func seen(_ computer: ClientComputer) {
        let now = Date()
        if let i = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[i].computer = computer
            computers[i].lastSeen = now
        } else {
            computers.insert(Known(computer: computer, allowed: nil, firstSeen: now, lastSeen: now), at: 0)
        }
        save()
    }

    func set(_ id: String, allowed: Bool) {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        computers[i].allowed = allowed
        save()
    }

    /// Off the list: its next session is new again and waits for the owner.
    func forget(_ id: String) {
        computers.removeAll { $0.id == id }
        save()
    }

    var waiting: [Known] { computers.filter { $0.allowed == nil } }

    private func save() {
        if computers.count > 50 { computers = Array(computers.prefix(50)) }
        if let data = try? JSONEncoder().encode(computers) { UserDefaults.standard.set(data, forKey: Self.listKey) }
        var answers: [String: Bool] = [:]
        for known in computers { if let allowed = known.allowed { answers[known.id] = allowed } }
        UserDefaults.standard.set(answers, forKey: Self.accessKey)
    }
}

/// The Computers section on Agents: each computer with its switch, the agent and the way it came
/// (USB, Wi-Fi or the relay), and when it was last here.
struct ComputersSection: View {
    @State private var access = ComputerAccess.shared

    var body: some View {
        if !access.computers.isEmpty {
            Section {
                ForEach(access.computers) { known in
                    Toggle(isOn: Binding(get: { known.allowed == true }, set: { access.set(known.id, allowed: $0) })) {
                        // The computer names itself: its name is shown as it is, never looked up as a key.
                        SettingsRow(title: LocalizedStringKey("\(known.computer.name)"), caption: caption(known),
                                    symbol: "laptopcomputer", warns: known.allowed == nil)
                    }
                    .accessibilityIdentifier("agents.computer")
                    .swipeActions { Button("Forget", role: .destructive) { access.forget(known.id) } }
                    .contextMenu { Button("Forget This Computer", systemImage: "xmark.circle", role: .destructive) { access.forget(known.id) } }
                }
            } header: {
                Group {
                    SettingsHeader("Computers")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Computers with Poki MCP from Poki Setup. A new computer can’t act on this iPhone until you turn it on here. Turning one off stops it at its next step.")
                }
                .settingsFooter()
            }
        }
    }

    private func caption(_ known: Known) -> LocalizedStringKey {
        let way: String = switch known.computer.transport {
        case "usb": AppLocalization.text("USB")
        case "wifi": AppLocalization.text("Wi-Fi")
        default: AppLocalization.text("Relay")
        }
        let agent = known.computer.agent.map(AgentName.pretty) ?? AppLocalization.text("Poki MCP")
        if known.allowed == nil {
            return LocalizedStringKey("\(AppLocalization.text(LocalizedStringResource("Waiting for you, \(agent) over \(way)")))")
        }
        return LocalizedStringKey("\(AppLocalization.text(LocalizedStringResource("\(agent) over \(way), \(ChatTime.row(known.lastSeen))")))")
    }

    private typealias Known = ComputerAccess.Known
}
