import AppKit
import SwiftUI

@main
struct PokiSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Poki Setup", id: "main") {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, SetupLocalization.shared.locale)
                .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 640)
                .tint(.pokiBlue)
                .task { model.start() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Poki") {
                Button(localized("Set Up a Device")) { model.page = .setup }.keyboardShortcut("1")
                Button(localized("Devices")) { model.page = .phones }.keyboardShortcut("2")
                Button(localized("Apple Account")) { model.page = .account }.keyboardShortcut("3")
                Button(localized("Test Builds")) { model.page = model.dev.signedIn ? .testBuilds : .github }.keyboardShortcut("4")
                Button(localized("GitHub Account")) { model.page = .github }.keyboardShortcut("5")
                Divider()
                Button(localized("Renew Signatures Now")) { Task { await model.renewDue() } }
                Divider()
                Button(localized("Copy Prompt for Your Agent")) { Task { await model.copyAgentPrompt() } }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.locale, SetupLocalization.shared.locale)
                .tint(.pokiBlue)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
                .environment(\.locale, SetupLocalization.shared.locale)
        } label: {
            Image(systemName: "iphone.gen3.badge.play")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps the app in the menu bar, so it can keep Poki signed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["POKI_SETUP_SNAPSHOT_DIR"], !dir.isEmpty {
            Task { @MainActor in await Snapshots.run(into: URL(fileURLWithPath: dir)) }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.records.isEmpty {
            Text(localized("No devices set up yet"))
        } else {
            ForEach(model.records) { r in
                Text("\(r.phoneName): \(relativeDays(r))")
            }
        }
        Divider()
        Button(localized("Open Poki Setup")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(localized("Renew Now")) { Task { await model.renewDue() } }
        Button(localized("Copy Prompt for Your Agent")) { Task { await model.copyAgentPrompt() } }
            .disabled(model.records.isEmpty)
        Divider()
        Button(localized("Quit Poki Setup")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

extension Color {
    /// Poki's blue, as on poki.app and in the iPhone app.
    static let pokiBlue = Color(red: 0 / 255, green: 119 / 255, blue: 253 / 255)
}
