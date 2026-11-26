import Foundation
import OSLog
import SwiftUI
import UIKit

/// Get Debug Bundle (Settings › Advanced): one zip of what Poki's maintainers need to debug, built on
/// this iPhone and handed to the share sheet (the owner, Nov 21 2026, in place of Share Run Log for
/// Maintainers). It holds the app and device, Poki's own log and today's system log lines, the setup
/// and connection state, Screen History's status and counts, model and provider names, settings that
/// are not secret, and the skill and task run summaries. It never holds keys, tokens, passwords,
/// pairing records, memory, chat text, screen text or screenshots, and every file passes through
/// `DebugRedactor` on the way in.
enum DebugBundle {
    /// The files a bundle holds, by name, as `manifest.json` lists them.
    static let fileNames = ["manifest.json", "state.json", "app-log.txt", "system-log.txt", "runs.json", "startup.log"]

    /// UserDefaults keys never copied, by any part of their name, whatever the value.
    static let secretKeyWords = ["key", "token", "secret", "password", "passcode", "pin", "auth", "cookie", "credential", "pairing", "relay", "session", "memory", "note", "chat", "message", "history.text"]

    struct Manifest: Codable, Equatable {
        var app: String
        var version: String
        var build: String
        var commit: String
        var ios: String
        var device: String
        var locale: String
        var languages: [String]
        var created: Date
        var files: [String]
    }

    static func manifest(files: [String], now: Date = Date()) -> Manifest {
        let info = Bundle.main.infoDictionary ?? [:]
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Manifest(app: Bundle.main.bundleIdentifier ?? "Poki",
                        version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                        build: info["CFBundleVersion"] as? String ?? "unknown",
                        commit: info["PokiCommit"] as? String ?? "unknown",
                        ios: UIDevice.current.systemVersion,
                        device: model,
                        locale: Locale.current.identifier,
                        languages: Locale.preferredLanguages,
                        created: now,
                        files: files)
    }

    /// The bundle's name: Poki-Debug-<build>-<date>.zip.
    static func fileName(build: String, at date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmm"
        return "Poki-Debug-\(build)-\(format.string(from: date)).zip"
    }

    /// Settings that are plain switches, numbers or short words, from Poki's own defaults only.
    static func settings(_ defaults: [String: Any]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in defaults where !key.hasPrefix("Apple") && !key.hasPrefix("NS") && !key.hasPrefix("com.apple") {
            let lower = key.lowercased()
            guard !secretKeyWords.contains(where: { lower.contains($0) }) else { continue }
            switch value {
            case let flag as Bool: kept[key] = flag ? "true" : "false"
            case let number as NSNumber: kept[key] = number.stringValue
            case let word as String where word.count <= 64: kept[key] = DebugRedactor.redact(word)
            default: continue
            }
        }
        return kept
    }

    /// Poki's own lines in the system log from the last day (this process only, as iOS allows).
    static func systemLog(since: Date) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "" }
        let position = store.position(date: since)
        let subsystem = Bundle.main.bundleIdentifier ?? "nz.zheha.poki"
        let format = ISO8601DateFormatter()
        var lines: [String] = []
        if let entries = try? store.getEntries(at: position) {
            for case let entry as OSLogEntryLog in entries where entry.subsystem.hasPrefix(subsystem) || entry.subsystem.hasPrefix("nz.zheha") {
                lines.append("\(format.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
                if lines.count >= 5000 { break }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The state that explains most reports: setup, the connection, automation, Screen History's status
    /// and counts (never its contents), models by name, and settings that are not secret.
    @MainActor static func state(model: AppModel) async -> [String: Any] {
        let capture = HistoryCapture.shared
        let size = await HistoryStore.shared.size()
        let setup = model.setup
        return [
            "setup": [
                "developer_mode": setup.developerMode,
                "ui_automation": setup.uiAutomation,
                "passcode_noted": setup.passcodeNoted,
                "loopback": setup.loopback.rawValue,
                "proxy_app": setup.proxyApp ?? "",
                "runner_installed": setup.runnerInstalled,
                "pairing_file_present": setup.pairingFile != nil,
                "steps": Dictionary(uniqueKeysWithValues: SetupStep.shown.map { ($0.rawValue, model.stepReadyForUse($0)) }),
            ],
            "connection": [
                "automation_path": String(describing: model.automationPath),
                "session_on": model.sessionOn,
                "loopback_state": String(describing: model.loopback.state),
                "loopback_working": model.loopback.isWorking,
                "wifi": model.loopback.onWiFi,
                "network_path": model.loopback.pathSummary,
                "pairing_checked": model.pairingVerifiedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "loopback_shortcut_set_up": HistoryReconnect.shared.isSetUp,
                "loopback_shortcut_last_run": HistoryReconnect.shared.lastAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "loopback_shortcut_last_worked": HistoryReconnect.shared.lastWorked,
            ],
            "approvals": [
                "method": model.approvalMode.rawValue,
                "automatic_unlock": model.autoUnlock.enabled,
            ],
            "screen_history": [
                "enabled": capture.enabled,
                "status": String(describing: capture.status),
                "entries": size.entries,
                "bytes": size.bytes,
            ],
            "models": [
                "chat_provider": ModelKeys.selectedProvider.name,
                "chat_model": ModelKeys.selectedModelName,
                "has_usable_key": ModelKeys.hasUsableKey,
            ],
            "settings": settings(UserDefaults.standard.dictionaryRepresentation()),
        ]
    }

    /// Builds the zip in the temporary folder and returns where it is.
    @MainActor static func build(model: AppModel) async throws -> URL {
        let now = Date()
        let state = await state(model: model)
        let appLog = AppLog.shared.lines.joined(separator: "\n")
        let runs = ChatDebugLog.exportBundle()
        let startup = try? String(contentsOf: AppFiles.support.appendingPathComponent("startup.log"), encoding: .utf8)
        let manifest = manifest(files: fileNames, now: now)
        return try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Poki-Debug-\(UUID().uuidString)", isDirectory: true)
            let contents = folder.appendingPathComponent("Poki-Debug", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            func write(_ text: String, _ name: String) throws {
                try Data(DebugRedactor.redact(text).utf8).write(to: contents.appendingPathComponent(name))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try write(String(decoding: try encoder.encode(manifest), as: UTF8.self), "manifest.json")
            let stateData = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try write(String(decoding: stateData, as: UTF8.self), "state.json")
            try write(appLog, "app-log.txt")
            try write(systemLog(since: now.addingTimeInterval(-86_400)), "system-log.txt")
            try write(String(decoding: runs, as: UTF8.self), "runs.json")
            try write(startup ?? "", "startup.log")
            let zip = try zipped(contents)
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(build: manifest.build, at: now))
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: zip, to: target)
            return target
        }.value
    }

    /// The folder as one zip, by the system's own archiver (a coordinated read for uploading).
    static func zipped(_ folder: URL) throws -> URL {
        var result: URL?
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zip in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
            do { try FileManager.default.copyItem(at: zip, to: copy); result = copy } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}

/// Takes out what looks like a secret: API keys, bearer and JSON web tokens, values of fields named
/// like secrets, long random strings, and email addresses. Run over every file in a debug bundle.
enum DebugRedactor {
    static let mark = "[redacted]"

    private static let patterns: [(NSRegularExpression, String)] = {
        func rule(_ pattern: String, _ template: String = mark) -> (NSRegularExpression, String) {
            (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), template)
        }
        return [
            // First, so the field rule below does not take the word Bearer for the whole value.
            rule(#"\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer " + mark),
            // Fields named like secrets, in JSON, in key=value and in key: value. The name stays.
            rule(#"("?[A-Za-z_\-]*(?:api[_\-]?key|token|secret|password|passcode|authorization|cookie|client[_\-]?secret|refresh)[A-Za-z_\-]*"?\s*[:=]\s*"?)(?!(?:true|false|null)\b)[^\s",}&]+"#, "$1" + mark),
            rule(#"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#),
            rule(#"\b(?:sk|pk|rk|xox[abp])-[A-Za-z0-9_\-]{12,}"#),
            rule(#"\bAIza[0-9A-Za-z_\-]{20,}"#),
            rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
            // Long random strings: 32 or more key-like characters with letters and digits mixed.
            rule(#"\b(?=[A-Za-z0-9+/_\-]*[0-9])(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{32,}={0,2}"#),
        ]
    }()

    static func redact(_ text: String) -> String {
        var out = text
        for (pattern, template) in patterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

/// The system's share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Advanced row: builds the bundle, shows that it is building, then opens the share sheet.
struct DebugBundleRow: View {
    @Environment(AppModel.self) private var model
    @State private var building = false
    @State private var bundle: URL?
    @State private var failed = false

    var body: some View {
        Button {
            guard !building else { return }
            building = true
            Task {
                defer { building = false }
                do { bundle = try await DebugBundle.build(model: model) } catch { failed = true }
            }
        } label: {
            HStack {
                SettingsRow(title: "Get Debug Bundle", symbol: "shippingbox")
                if building { ProgressView().accessibilityLabel(Text("Building")) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(building)
        .accessibilityIdentifier("advanced.debugBundle")
        .sheet(item: Binding(get: { bundle.map(SharedFile.init) }, set: { if $0 == nil { bundle = nil } })) { file in
            ShareSheet(items: [file.url]).ignoresSafeArea()
        }
        .alert("Couldn’t Make the Debug Bundle", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    private struct SharedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}
