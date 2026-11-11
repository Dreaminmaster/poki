import Foundation

/// `-pokiInProcess web -pokiProbeModelURL URL -pokiProbeModel ID -pokiProbeTask TEXT`: Poki's own browser
/// end to end in the app (ESP-145), with no phone automation. The chat is pointed at an
/// OpenAI-compatible endpoint, gets the task as if the owner had typed it, and the agent works the
/// website in Poki's browser on screen. The tool calls, replies and browser steps go to
/// Documents/web-probe.json. `-pokiProbeTakeOver S` takes the page over S seconds after the task starts
/// and hands it back `-pokiProbeHold` seconds later; `-pokiProbeStop S` presses Stop S seconds in. Both
/// run what the panel's buttons run.
@MainActor
enum WebDemo {
    static func run() async {
        let defaults = UserDefaults.standard
        ModelKeys.customURL = defaults.string(forKey: "pokiProbeModelURL") ?? "http://127.0.0.1:8765/v1"
        ModelKeys.customModel = defaults.string(forKey: "pokiProbeModel") ?? "poki-mock"
        ModelKeys.selectedProvider = .custom
        guard let chat = AskPoki.chat else { write(["error": "no chat"]); return }
        // Time for the screen recording to start on a calm chat.
        try? await Task.sleep(for: .seconds(max(1, defaults.double(forKey: "pokiProbeWait"))))
        chat.newConversation()
        let task = defaults.string(forKey: "pokiProbeTask") ?? "Find showtimes for Dune on Fandango."
        let started = Date()
        chat.send(task)
        var events: [String] = []
        let takeOver = defaults.double(forKey: "pokiProbeTakeOver"), stop = defaults.double(forKey: "pokiProbeStop")
        if takeOver > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(takeOver))
                PokiBrowser.shared.takeOver()
                events.append("took over at \(Int(Date().timeIntervalSince(started))) s")
                try? await Task.sleep(for: .seconds(max(2, defaults.double(forKey: "pokiProbeHold"))))
                PokiBrowser.shared.handBack()
                events.append("handed back at \(Int(Date().timeIntervalSince(started))) s")
            }
        }
        if stop > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(stop))
                chat.stop()
                PokiBrowser.shared.taskStopped()
                events.append("stopped at \(Int(Date().timeIntervalSince(started))) s")
            }
        }
        for _ in 0..<2400 where chat.running { try? await Task.sleep(for: .milliseconds(250)) }
        let seconds = Date().timeIntervalSince(started)
        write([
            "task": task,
            "seconds": seconds,
            "running": chat.running,
            "events": events,
            "calls": chat.savedCalls.map { ["name": $0.name, "ok": $0.ok, "ms": $0.ms, "arguments": String($0.arguments.prefix(300)), "answer": String($0.answer.prefix(600))] },
            "replies": chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } },
            "problems": chat.entries.compactMap { if case .note(.problem(let why)) = $0.kind { why } else { nil } },
            "steps": PokiBrowser.shared.steps.map { ["text": $0.text, "state": "\($0.state)", "ms": $0.ms] },
            "page": PokiBrowser.shared.webView.url?.absoluteString ?? "",
        ])
    }

    private static func write(_ object: [String: Any]) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: documents.appendingPathComponent("web-probe.json"))
    }
}
