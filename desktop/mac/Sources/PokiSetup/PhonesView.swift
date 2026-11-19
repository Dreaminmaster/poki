import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PhonesView: View {
    @EnvironmentObject var model: AppModel
    @State private var forgetting: Record?

    var body: some View {
        Group {
            if model.records.isEmpty {
                EmptyState(symbol: "ipad.and.iphone", title: localized("No Devices Yet"), message: localized("iPhones and iPads you set up with Poki Setup appear here, with how long Poki stays signed."))
            } else {
                Form {
                    HeroSection {
                        PageHero(symbol: "ipad.and.iphone", title: localized("Devices"), subtitle: localized("Poki Setup renews Poki before it stops opening, every few hours while this Mac is on."))
                    }
                    ForEach(model.records) { r in section(r) }
                }
                .pokiPage()
            }
        }
        .confirmationDialog(localized("Forget \(forgetting?.phoneName ?? localized("this device"))?"), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { r in
            Button(localized("Forget"), role: .destructive) { Task { await model.forget(udid: r.udid) } }
        } message: { _ in
            Text(localized("Poki stays on the device, but Poki Setup stops renewing it."))
        }
        .task { await model.refreshRecords() }
    }

    @ViewBuilder private func section(_ r: Record) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: deviceSymbol(model.phones.first(where: { $0.id == r.udid })?.facts?.productType, name: r.phoneName)).font(.system(size: 28, weight: .light)).foregroundStyle(Color.pokiBlue).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.phoneName).font(.headline)
                    Text("iOS \(r.ios) · Poki \(r.version) (\(r.build))").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ExpiryBadge(record: r)
            }
            .padding(.vertical, 4)
            if let t = r.testBuild {
                LabeledContent(localized("Test Build")) {
                    Text(localized("Build \(t.runNumber) from \(t.branch), \(String(t.sha.prefix(7)))")).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            LabeledContent(localized("Signed")) { Text(Date(timeIntervalSince1970: TimeInterval(r.signedAt)), format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
            LabeledContent(localized("Stays Signed Until")) { Text(r.expires, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
            LabeledContent(localized("Team")) { Text(r.teamIsFree ? localized("\(r.teamName), free") : r.teamName).foregroundStyle(.secondary) }
            LabeledContent(localized("Bundle ID")) { Text(r.bundleId).foregroundStyle(.secondary).textSelection(.enabled) }
            if let e = r.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let steps = model.steps["renew"], !steps.isEmpty, model.busyJobs.contains("renew") {
                JobProgress(steps: steps, running: true, weights: JobProgress.renew)
            }
            LabeledContent(localized("Agent Memory")) {
                HStack {
                    Button(localized("Back Up…")) { Task { await backup(r) } }
                    Button(localized("Restore…")) { Task { await restore(r) } }
                }
            }
            HStack {
                Button(localized("Forget…"), role: .destructive) { forgetting = r }
                Spacer()
                Button(localized("Renew Now")) {
                    Task {
                        do { try await model.renew(udid: r.udid) } catch { model.report(error) }
                    }
                }
                .pokiProminentButton()
                .disabled(model.busyJobs.contains("renew"))
            }
        }
    }
}

extension PhonesView {
    struct Saved: Decodable { var path: String; var bytes: Int }

    func backup(_ r: Record) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = localized("Save Backup Here")
        panel.message = localized("Poki Setup copies the agent's routines, notes and settings (no passwords) from \(r.phoneName).")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let saved: Saved = try await model.bridge.call("backup_agent", ["udid": r.udid, "out_dir": dir.path])
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved.path)])
        } catch { model.report(error) }
    }

    func restore(_ r: Record) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = localized("Restore")
        panel.message = localized("Choose a Poki agent backup. Poki imports it the next time it opens.")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try await model.bridge.run("restore_agent", ["udid": r.udid, "file": file.path])
            model.banner = .copy("The backup is on \(r.phoneName). Open Poki to import it.")
        } catch { model.report(error) }
    }
}

struct ExpiryBadge: View {
    var record: Record

    var body: some View {
        let color: Color = record.isExpired ? .red : (record.daysLeft <= 2 ? .orange : .green)
        Text(relativeDays(record))
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
