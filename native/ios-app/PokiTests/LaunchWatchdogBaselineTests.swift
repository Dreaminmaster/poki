import CryptoKit
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// Regression check using only pre-fix public types/initializers so it compiles verbatim and fails
/// on the unpatched baseline (`77254611`), while passing after moving launch heavy work off main.
@MainActor
final class LaunchWatchdogBaselineTests: XCTestCase {
    private var ddiBackup: URL?

    override func tearDown() async throws {
        if let ddiBackup {
            let ddi = AppFiles.ddiDirectory
            try? FileManager.default.removeItem(at: ddi)
            try? FileManager.default.moveItem(at: ddiBackup, to: ddi)
            self.ddiBackup = nil
        }
    }

    private func seedDiskImageFixture(imageBytesCount: Int = 80 * 1024 * 1024) throws {
        let ddi = AppFiles.ddiDirectory
        if FileManager.default.fileExists(atPath: ddi.path) {
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("ddi-baseline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: ddi, to: backup)
            ddiBackup = backup
        }
        try FileManager.default.createDirectory(at: ddi, withIntermediateDirectories: true)
        let payloads: [(key: String, path: String, data: Data)] = [
            ("Cryptex1,GenericDmg", "Image.dmg", Data(repeating: 0x5A, count: imageBytesCount)),
            ("Cryptex1,GenericTrustCache", "Image.dmg.trustcache", Data("trustcache".utf8)),
            ("Cryptex1,CryptexInfoPlist", "Image.dmg.cryptex_info", Data("cryptex".utf8)),
            ("Cryptex1,GenericVolume", "Image.dmg.root_hash", Data("roothash".utf8)),
        ]
        var manifestEntries: [String: Any] = [:]
        for payload in payloads {
            try payload.data.write(to: ddi.appendingPathComponent(payload.path))
            manifestEntries[payload.key] = [
                "Digest": Data(SHA384.hash(data: payload.data)),
                "Info": ["Path": payload.path],
            ]
        }
        let manifest: [String: Any] = [
            "ProductBuildVersion": "99Z999",
            "BuildIdentities": [["Manifest": manifestEntries]],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try plistData.write(to: ddi.appendingPathComponent("BuildManifest.plist"))
    }

    func testDiskImageAndAppModelInitDoNotVerifySynchronouslyOnMainThread() throws {
        try seedDiskImageFixture()

        let t0 = ContinuousClock.now
        let diskImage = DiskImageStore()
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let chat = ChatModel(app: model)
        let elapsed = ContinuousClock.now - t0
        defer { model.stopSession(); _ = chat }

        XCTAssertEqual(diskImage.state, .missing, "DiskImageStore.init must not synchronously SHA-384 verify 80 MB DDI on the main thread")
        XCTAssertEqual(model.diskImage.state, .missing, "AppModel.init must keep DDI verification off the launch main thread")
        XCTAssertLessThan(elapsed, .milliseconds(150), "AppModel + DiskImageStore init with 80 MB DDI must return immediately (took \(elapsed))")
    }
}
