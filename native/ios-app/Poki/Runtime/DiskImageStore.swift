import Foundation
import PokiCore

/// The developer disk image the launcher mounts, kept in the app's container. PokiCore's
/// DeveloperDiskImage downloads it once from the public mirror and checks every file against the
/// SHA-384 digests in its BuildManifest.plist; this tracks the state for the setup screen.
@MainActor
@Observable
final class DiskImageStore {
    enum State: Equatable { case missing, downloading(String), downloaded(String), ready(String), failed(String) }
    private(set) var state: State = .missing
    static let unavailableMessage: LocalizedStringResource = "The disk image is downloaded, but its developer tools are not available on this iPhone. Try turning Automation on. If it still fails, connect to a computer and prepare this iPhone again in Poki Setup."
    static let loadFailureMessage: LocalizedStringResource = "Poki could not load the developer tools. Connect this iPhone to a computer and prepare it again in Poki Setup, then reopen Poki and turn Automation on."

    init() {
        if let build = try? DeveloperDiskImage.verify(AppFiles.ddiDirectory) { record(build) }
    }

    /// Files that appeared since (Poki Setup puts them in the container): counted without downloading.
    func notice() {
        if hasFiles { refreshAvailability(); return }
        guard let build = try? DeveloperDiskImage.verify(AppFiles.ddiDirectory) else { return }
        record(build)
    }

    func refreshAvailability() {
        switch state {
        case .ready(let build), .downloaded(let build): record(build)
        default: break
        }
    }

    private func record(_ build: String) {
        state = PKInProcess.shared().developerFrameworksAvailable() ? .ready(build) : .downloaded(build)
    }

    /// Checks the files again (they can be damaged or removed); false starts a fresh download.
    func recheck() -> Bool {
        if let build = try? DeveloperDiskImage.verify(AppFiles.ddiDirectory) { record(build); return true }
        state = .missing
        Task { await download() }
        return false
    }

    /// The phone would not install the image: delete it and download it again.
    func redownload() {
        if case .downloading = state { return }
        try? FileManager.default.removeItem(at: AppFiles.ddiDirectory)
        state = .missing
        Task { await download() }
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }
    var hasFiles: Bool {
        switch state {
        case .ready, .downloaded: true
        default: false
        }
    }

    func download() async {
        if case .downloading = state { return }
        state = .downloading("Starting…")
        do {
            let build = try await DeveloperDiskImage.ensure(in: AppFiles.ddiDirectory) { step in
                Task { @MainActor [weak self] in if case .downloading = self?.state { self?.state = .downloading(step) } }
            }
            record(build)
        } catch {
            state = .failed("\(error)")
        }
    }
}
