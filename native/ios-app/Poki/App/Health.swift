import SwiftUI

/// A status word and the colour of its dot.
struct Health {
    var word: String
    var color: Color
    static let off = Color.white.opacity(0.48)

    @MainActor static func relay(_ model: AppModel) -> Health {
        switch model.relayStatus {
        case .ready: Health(word: AppLocalization.text(LocalizedStringResource("Online")), color: Site.ok)
        case .connecting: Health(word: AppLocalization.text(LocalizedStringResource("Connecting")), color: .white)
        case .offline: Health(word: AppLocalization.text(LocalizedStringResource("Offline")), color: Site.bad)
        case .off: Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: off)
        }
    }

    @MainActor static func relayStatusText(_ model: AppModel) -> String {
        relayStatusText(model.relayStatus)
    }

    static func relayStatusText(_ status: RelayStatus) -> String {
        switch status {
        case .ready:
            return AppLocalization.text(LocalizedStringResource("Online"))
        case .connecting:
            return AppLocalization.text(LocalizedStringResource("Connecting"))
        case .off:
            return AppLocalization.text(LocalizedStringResource("Off"))
        case .offline(let why):
            let word = AppLocalization.text(LocalizedStringResource("Offline"))
            let reason = relayOfflineReason(why)
            guard !reason.isEmpty else { return word }
            return AppLocalization.text(LocalizedStringResource("\(word): \(reason)"))
        }
    }

    /// Maps raw relay/network offline errors from PokiCore into localized user-facing text so
    /// Chinese UI never exposes raw English error descriptions or NSError dumps.
    static func relayOfflineReason(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()

        if lower == "stopped" {
            return AppLocalization.text(LocalizedStringResource("Stopped"))
        }
        if lower == "poki is shutting down" {
            return AppLocalization.text(LocalizedStringResource("Poki is shutting down"))
        }
        if lower.hasPrefix("connecting to the relay did not finish within") {
            return AppLocalization.text(LocalizedStringResource("Connection to the relay timed out"))
        }
        if lower.hasPrefix("the relay's challenge did not finish within")
            || lower.hasPrefix("the relay's ready did not finish within") {
            return AppLocalization.text(LocalizedStringResource("The relay did not respond in time"))
        }
        if lower == "the relay sent no challenge" {
            return AppLocalization.text(LocalizedStringResource("Unexpected response from the relay"))
        }
        if let detail = extractSuffix(trimmed, prefix: "the relay refused the phone:") {
            return localizedRelayServerReason(
                detail,
                plain: LocalizedStringResource("The relay refused this iPhone"),
                withCode: { code in LocalizedStringResource("The relay refused this iPhone (\(code))") }
            )
        }
        if let detail = extractSuffix(trimmed, prefix: "the relay closed the connection:") {
            return localizedRelayServerReason(
                detail,
                plain: LocalizedStringResource("The relay closed the connection"),
                withCode: { code in LocalizedStringResource("The relay closed the connection (\(code))") }
            )
        }
        if lower.contains("code=-1009") || lower.contains("appears to be offline") || lower.contains("not connected to the internet") {
            return AppLocalization.text(LocalizedStringResource("No internet connection"))
        }
        if lower.contains("code=-1001") || lower.contains("timed out") || lower.contains("did not finish within") {
            return AppLocalization.text(LocalizedStringResource("Connection timed out"))
        }
        if lower.contains("code=-1003") || lower.contains("hostname could not be found") || lower.contains("cannot find host") {
            return AppLocalization.text(LocalizedStringResource("Could not find the relay server"))
        }
        if lower.contains("code=-1004") || lower.contains("code=61") || lower.contains("could not connect") || lower.contains("connection refused") {
            return AppLocalization.text(LocalizedStringResource("Could not connect to the relay server"))
        }
        if lower.contains("code=-1005") || lower.contains("code=57") || lower.contains("code=54")
            || lower.contains("connection was lost") || lower.contains("socket is not connected")
            || lower.contains("connection reset") || lower == "closed" {
            return AppLocalization.text(LocalizedStringResource("Connection was interrupted"))
        }
        if lower.contains("code=-1200") || lower.contains("code=-1201") || lower.contains("code=-1202")
            || lower.contains("code=-1203") || lower.contains("code=-1204") || lower.contains("code=-1205")
            || lower.contains("code=-1206") || lower.contains("ssl") || lower.contains("tls")
            || lower.contains("certificate") || lower.contains("secure connection") {
            return AppLocalization.text(LocalizedStringResource("Secure connection failed"))
        }
        if lower.contains("code=-1011") || lower.contains("bad server response") || lower.contains("json") {
            return AppLocalization.text(LocalizedStringResource("Unexpected response from the relay"))
        }
        return AppLocalization.text(LocalizedStringResource("Connection failed"))
    }

    private static func extractSuffix(_ text: String, prefix: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localizedRelayServerReason(
        _ detail: String,
        plain: LocalizedStringResource,
        withCode: (String) -> LocalizedStringResource
    ) -> String {
        let lower = detail.lowercased()
        if detail.isEmpty || lower == "no reason" {
            return AppLocalization.text(plain)
        }
        if lower.contains("replaced") || lower.contains("superseded") {
            return AppLocalization.text(LocalizedStringResource("Connection replaced by a newer session"))
        }
        if lower.contains("signature") || lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("auth") {
            return AppLocalization.text(LocalizedStringResource("Relay authentication failed"))
        }
        let isShortMachineCode = detail.count <= 32
            && !detail.contains(" ")
            && !detail.contains("{")
            && !detail.contains("=")
        if isShortMachineCode {
            return AppLocalization.text(withCode(detail))
        }
        return AppLocalization.text(plain)
    }

    @MainActor static func runner(_ model: AppModel) -> Health {
        guard model.sessionOn else { return Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: off) }
        let runner = model.runner
        let word = AppLocalization.bundle.localizedString(forKey: runner.title, value: runner.title, table: nil)
        if runner.isRunning { return Health(word: word, color: Site.ok) }
        if runner.state == "failed" { return Health(word: word, color: Site.bad) }
        return Health(word: word, color: model.runnerPaused ? off : .white)
    }

    @MainActor static func loopback(_ model: AppModel) -> Health {
        let monitor = model.loopback
        if !monitor.isWorking && model.hasOpenInProcessSession {
            return Health(word: AppLocalization.text(LocalizedStringResource("Local automation ready")), color: off)
        }
        switch monitor.state {
        case .working: return Health(word: AppLocalization.text(LocalizedStringResource("On")), color: Site.ok)
        case .checking: return Health(word: AppLocalization.text(LocalizedStringResource("Checking…")), color: .white)
        case .noAnswer: return Health(word: AppLocalization.text(LocalizedStringResource("No Answer")), color: Site.bad)
        case .off: return Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: Site.bad)
        }
    }
}

/// Something that keeps agents from using the phone, with the one thing the person has to do.
struct Issue: Identifiable {
    enum Fix { case setup, settings, retry, none }
    var id: String
    var title: String
    var text: String
    var fix: Fix

    var button: LocalizedStringKey? {
        switch fix {
        case .setup: "Open Setup"
        case .settings: "Open Settings"
        case .retry: "Try Again"
        case .none: nil
        }
    }

    @MainActor func act(_ model: AppModel, openSetup: () -> Void) {
        switch fix {
        case .setup: openSetup()
        case .settings: if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .retry: model.runnerPaused ? model.wakeRunner() : model.restartRunner()
        case .none: break
        }
    }

    /// Text from PokiCore and the launcher stays as it came; Poki's own sentences are localized.
    static func localizedProblem(_ text: String) -> String {
        let refusedPrefix = "The phone refused the pairing ("
        let refusedSuffix = "). Pair again in Setup."
        if text.hasPrefix(refusedPrefix), text.hasSuffix(refusedSuffix) {
            let start = text.index(text.startIndex, offsetBy: refusedPrefix.count)
            let end = text.index(text.endIndex, offsetBy: -refusedSuffix.count)
            let inner = String(text[start..<end])
            let format = AppLocalization.bundle.localizedString(
                forKey: "The phone refused the pairing (%@). Pair again in Setup.",
                value: "The phone refused the pairing (%@). Pair again in Setup.",
                table: nil
            )
            return String(format: format, locale: AppLocalization.locale, inner)
        }
        return AppLocalization.bundle.localizedString(forKey: text, value: text, table: nil)
    }

    private static func local(_ text: String) -> String { localizedProblem(text) }

    @MainActor static func current(_ model: AppModel) -> [Issue] {
        var out: [Issue] = []
        if model.sessionOn {
            let runner = model.runner
            if runner.state == "failed", model.pairingTrouble == nil {
                let fix = runner.fix ?? ""
                let kind: Fix = switch runner.code {
                case "runner", "pairing", "handshake", "unreachable", "ddi_refused": .setup
                case "developer_mode", "no_cryptexd", "ios_too_old", "runner_blocked": .settings
                default: .retry
                }
                out.append(Issue(id: "runner", title: AppLocalization.text(LocalizedStringResource("The runner stopped")),
                                 text: fix.isEmpty ? (runner.detail.map { "\($0.prefix(1).uppercased())\($0.dropFirst())." } ?? AppLocalization.text(LocalizedStringResource("Poki starts it again on the next agent request."))) : local(fix), fix: kind))
            } else if runner.state == "waiting_network", let fix = runner.fix, fix.contains("internet") {
                out.append(Issue(id: "network", title: AppLocalization.text(LocalizedStringResource("Waiting for the internet")), text: local(fix), fix: .none))
            } else if let trouble = model.localSessionTrouble {
                out.append(Issue(id: "local", title: AppLocalization.text(LocalizedStringResource("Automation did not start")), text: trouble.text, fix: trouble.opensSetup ? .setup : .none))
            } else if model.loopback.proxyAnswers, !model.loopback.isWorking, !model.hasOpenInProcessSession, !model.canStartTasks, !model.mountedImageStandsIn {
                // The proxy's setting is the fix, on cellular too: not Wi-Fi and not the generic advice.
                out.append(Issue(id: "proxy", title: LoopbackMonitor.proxyTitle, text: LoopbackMonitor.proxyHint, fix: .setup))
            } else if model.loopback.cellularRefused {
                // On the mounted image a new task starts without the loopback; only the mount needs Wi-Fi.
                if model.cellularNeedsWiFi, !runner.isRunning {
                    out.append(Issue(id: "cellular", title: AppLocalization.text(LocalizedStringResource("Connect to Wi-Fi first")), text: LoopbackMonitor.needsWiFi, fix: .none))
                }
            } else if !model.hasOpenInProcessSession, !model.canStartTasks, !model.mountedImageStandsIn, runner.code != "local_ddi",
                      (runner.state == "waiting_network" && runner.code != "pairing_port" && !model.loopback.isWorking)
                      || (!model.loopback.isWorking && model.loopback.state != .checking) {
                out.append(Issue(id: "loopback", title: AppLocalization.text(LocalizedStringResource("Loopback is off")),
                                 text: AppLocalization.text(LocalizedStringResource("Turn on your proxy app with the Poki module, or connect LocalDevVPN.")), fix: .setup))
            }
            if let trouble = model.pairingTrouble {
                out.append(Issue(id: "pairing", title: AppLocalization.text(LocalizedStringResource("Pair this iPhone again")),
                                 text: AppLocalization.text(LocalizedStringResource("The phone no longer accepts Poki’s pairing (\(trouble)). Pair again in Setup; it takes a minute.")), fix: .setup))
            }
            if model.passcodeHint {
                out.append(Issue(id: "passcode", title: AppLocalization.text(LocalizedStringResource("Enter the passcode if the iPhone asks")),
                                 text: model.automationPath == .inProcess
                                    ? AppLocalization.text(LocalizedStringResource("iOS asks for the passcode to allow UI Automation after Poki restarts, or 8 hours after it was last entered. Enter it once; Poki carries on by itself."))
                                    : AppLocalization.text(LocalizedStringResource("iOS asks for the passcode before UI Automation after Poki Runner was force-closed or the iPhone restarted. Enter it once; Poki carries on by itself.")), fix: .none))
            }
            if let text = model.handoffText {
                out.append(Issue(id: "handoff", title: AppLocalization.text(LocalizedStringResource("Your turn")),
                                 text: AppLocalization.text(LocalizedStringResource("\(text). The agent waits and sends nothing until you tap Done on the Live Activity.")), fix: .none))
            }
            if case .offline(let why) = model.relayStatus {
                let reason = Health.relayOfflineReason(why)
                let text = reason.isEmpty
                    ? AppLocalization.text(LocalizedStringResource("Poki is offline. Check that the phone has internet; Poki reconnects by itself."))
                    : AppLocalization.text(LocalizedStringResource("Poki is offline (\(reason)). Check that the phone has internet; Poki reconnects by itself."))
                out.append(Issue(id: "relay", title: AppLocalization.text(LocalizedStringResource("Agents can’t reach this iPhone")),
                                 text: text, fix: .none))
            }
            if model.background.denied {
                out.append(Issue(id: "location", title: AppLocalization.text(LocalizedStringResource("Poki can’t stay on in the background")),
                                 text: AppLocalization.text(LocalizedStringResource("Allow location access for Poki (Settings › Poki › Location › Always). Poki uses it only to keep running; it never records where you are.")), fix: .settings))
            }
        }
        if !model.sessionOn, model.cellularNeedsWiFi {
            out.append(Issue(id: "cellular", title: AppLocalization.text(LocalizedStringResource("Connect to Wi-Fi first")), text: LoopbackMonitor.needsWiFi, fix: .none))
        }
        if let problem = model.problem, !model.suppressesLoopbackProblem(problem) {
            out.append(Issue(id: "problem", title: AppLocalization.text(LocalizedStringResource("Needs attention")), text: local(problem), fix: problem.contains("Pair") || problem.contains("disk image") || problem.contains("Setup") ? .setup : .none))
        }
        if let problem = model.activityProblem {
            out.append(Issue(id: "activity", title: AppLocalization.text(LocalizedStringResource("Live Activity is off")), text: local(problem), fix: .settings))
        }
        return out
    }
}
