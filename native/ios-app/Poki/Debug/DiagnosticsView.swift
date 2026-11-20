import SwiftUI

/// Diagnostics under Advanced. It shows cellular preparation, connection checks and addresses.
struct DiagnosticsView: View {
    @Binding var path: [SettingsRoute]
    @State private var results: [ProbeResult] = []
    @State private var running = false
    @State private var addresses: [LocalAddress] = localAddresses()
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.automationPath == .inProcess {
                cellularStartup
            }
            Section {
                if let loop = loopbackInterface(addresses) {
                    Text(verbatim: "\(loop.interface)  \(loop.address)").font(.body.monospaced().weight(.semibold))
                    Text(loop.ipv6.isEmpty ? "No IPv6 on this interface" : "IPv6 present, \(loop.ipv6.joined(separator: ", "))")
                        .font(.footnote.monospaced()).foregroundStyle(loop.ipv6.isEmpty ? Color.secondary : Color.red)
                } else {
                    Text("No interface has a 10.7.0.x address. Check that your proxy app is on and its loopback module is enabled.")
                }
            } header: {
                Text("Proxy Loopback Interface")
            } footer: {
                Text(verbatim: "Network path: \(model.loopback.pathSummary). Wi-Fi \(model.loopback.wifiUp ? "up" : "down"), cellular \(model.loopback.cellularUp ? "up" : "down")\(model.loopback.cellularOnly ? " (cellular only)" : "")")
                    .textSelection(.enabled)
            }
            .textSelection(.enabled)
            Section("Checks") {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.title(r)).font(.subheadline.weight(.semibold))
                        Text(verbatim: "\(r.target)  \(r.milliseconds) ms").font(.caption.monospaced()).foregroundStyle(Color(.secondaryLabel))
                        if !r.detail.isEmpty { Text(verbatim: r.detail).font(.caption.monospaced()) }
                        if !r.firstBytes.isEmpty { Text(verbatim: "first bytes: \(r.firstBytes)").font(.caption.monospaced()) }
                    }
                    .textSelection(.enabled)
                }
                Button(running ? "Running…" : "Run Checks") { Task { await run() } }.disabled(running)
            }
            Section("Addresses") {
                ForEach(addresses.indices, id: \.self) { i in
                    Text(verbatim: "\(addresses[i].interface)  \(addresses[i].address)").font(.caption.monospaced())
                }
            }
            .textSelection(.enabled)
        }
        .navigationTitle(AppLocalization.text("Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
    }

    private var cellularStartup: some View {
        let preparation = model.cellularPreparation
        let imageStatus: LocalizedStringResource = preparation == .mounted ? "Mounted" : "Not Mounted"
        let detail: LocalizedStringResource = switch preparation {
        case .mounted: "Switch to cellular and run a new task to verify automation."
        case .automationOff: "Turn on Automation in Connection to prepare for cellular."
        case .needsLocalConnection: "Connect to Wi-Fi and check the local connection in Connection."
        case .busy: "Wait for the current task to finish before preparing for cellular."
        case .ready: "Prepare the developer disk image before switching to cellular."
        case .preparing: "Poki is preparing the developer disk image."
        case .retry: "The image is still not mounted. Check the local connection and try again."
        }
        return Section {
            LabeledContent("Developer Disk Image") {
                Text(AppLocalization.text(imageStatus))
            }
            Button("Prepare for Cellular", action: model.prepareForCellular)
                .disabled(!preparation.canPrepare)
        } header: {
            Text("Cellular Startup")
        } footer: {
            Text(AppLocalization.text(detail))
        }
    }

    /// "Reflected lockdown: Connected", the probe's own words with the address left to the line below.
    static func title(_ r: ProbeResult) -> String {
        let label = r.label.replacingOccurrences(of: " (10.7.0.1)", with: "")
        let outcome = r.outcome.prefix(1).uppercased() + r.outcome.dropFirst()
        func local(_ s: String) -> String { AppLocalization.bundle.localizedString(forKey: s, value: s, table: nil) }
        return AppLocalization.text(LocalizedStringResource("\(local(label)), \(local(outcome))"))
    }

    private func run() async {
        running = true
        addresses = localAddresses()
        results = await runChecks()
        running = false
    }
}

/// Poki's log, newest first, with Clear.
struct LogView: View {
    @State private var log = AppLog.shared
    var back: () -> Void
    var body: some View {
        List {
            ForEach(Array(log.lines.reversed().enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .listStyle(.plain)
        .overlay { if log.lines.isEmpty { ContentUnavailableView("No Log Yet", systemImage: "doc.text") } }
        .navigationTitle(AppLocalization.text("Log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy Log", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.text }
                    ShareLink(item: log.text, subject: Text("Poki log")) { Label("Share Log", systemImage: "square.and.arrow.up") }
                    Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel(Text("More"))
                }
            }
        }
    }
}

/// Poki › General › Testing Options: switches being tried, all in one place, and 752's Diagnostics
/// tools for testers: the automation path switch with its probes, and the background hold experiment.
/// Ask Before Sensitive Steps and the Auto-Classifier are in Poki › Approvals.
struct TestingOptionsView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var hold = Hold()
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("ask_poki Tool", isOn: $model.askPokiTool)
            } header: {
                Text("Agents")
            } footer: {
                Text("Off by default. ask_poki lets outside agents hand a repetitive task to Poki's own agent. Changes take effect the next time Poki opens. The Auto-Classifier is in Settings › Approvals.")
            }
            // Apps by name and the read that comes when the screen settles: on unless turned off here.
            SpeedTestingSection()
            // The in-process path's switch and probes (ESP-173, ESP-175).
            InProcessSection()
            Section {
                LabeledContent("Port on 10.7.0.1") {
                    TextField(text: $hold.port, prompt: Text(verbatim: "49152")) { Text("Port on 10.7.0.1") }
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                }
                Picker("Experiment", selection: $hold.experiment) {
                    ForEach(Hold.Experiment.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .disabled(hold.holding)
                Button("Start Hold") { hold.start() }.disabled(hold.holding)
                Button("Stop", role: .destructive) { hold.stop() }.disabled(!hold.holding)
                if !hold.log.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hold.log.indices, id: \.self) { i in Text(verbatim: hold.log[i]).font(.caption2.monospaced()) }
                    }
                    .textSelection(.enabled)
                }
            } header: {
                Text("Background Hold")
            } footer: {
                Text("Tap Start, leave the app for a while, then return. The log records suspension gaps and connection closures.")
            }
            Section {
                NavigationLink("Live Activity Preview") { ActivityPreview() }
            }
            // Whether a connection opened with no cellular stays open on cellular (issue 484).
            CellularTrickSection()
        }
        .navigationTitle(AppLocalization.text("Testing Options"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
