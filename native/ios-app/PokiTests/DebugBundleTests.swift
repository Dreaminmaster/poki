import XCTest
@testable import Poki

final class DebugBundleTests: XCTestCase {
    func testSecretsAreRedacted() {
        let cases: [(String, String)] = [
            ("key sk-ant-api03-abcdefghijklmnop1234 in a line", "sk-ant-api03-abcdefghijklmnop1234"),
            ("Authorization: Bearer abc.def-ghi_jkl", "abc.def-ghi_jkl"),
            (#"{"api_key": "AbCdEf123456"}"#, "AbCdEf123456"),
            ("password=hunter2&next=1", "hunter2"),
            ("refresh_token: r-1a2b3c", "r-1a2b3c"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl here", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"),
            ("signed in as someone@example.com", "someone@example.com"),
            ("gemini AIzaSyA1234567890abcdefghijk", "AIzaSyA1234567890abcdefghijk"),
            ("github ghp_abcdefghijklmnopqrstuvwx1234", "ghp_abcdefghijklmnopqrstuvwx1234"),
            ("host id 3f9a1c2b7d4e5f60718293a4b5c6d7e8f9012345", "3f9a1c2b7d4e5f60718293a4b5c6d7e8f9012345"),
        ]
        for (text, secret) in cases {
            let out = DebugRedactor.redact(text)
            XCTAssertFalse(out.contains(secret), "\(text) -> \(out)")
            XCTAssertTrue(out.contains(DebugRedactor.mark), out)
        }
    }

    func testOrdinaryLogLinesStayReadable() {
        for line in [#""passcode_noted" : true"#, "12:01:02.345 [runner] started: Look at the screen", "loopback proxy, Wi-Fi on, path satisfied", "Poki 0.4.7 (70) on iOS 27.3"] {
            XCTAssertEqual(DebugRedactor.redact(line), line)
        }
    }

    func testSettingsKeepSwitchesAndLeaveOutSecretNames() {
        let kept = DebugBundle.settings([
            "approvals.mode.v2": "confirm",
            "showsReadyActivity": true,
            "idleStopSeconds": 300,
            "openai.apiKey": "sk-abcdefghijklmnop12345",
            "relay.token": "abc",
            "history.pin": "1234",
            "AppleLanguages": ["en"],
            "long": String(repeating: "x", count: 100),
        ])
        XCTAssertEqual(kept["approvals.mode.v2"], "confirm")
        XCTAssertEqual(kept["showsReadyActivity"], "true")
        XCTAssertEqual(kept["idleStopSeconds"], "300")
        for gone in ["openai.apiKey", "relay.token", "history.pin", "AppleLanguages", "long"] {
            XCTAssertNil(kept[gone], gone)
        }
    }

    func testManifestNamesEveryFileAndTheBuild() throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let manifest = DebugBundle.manifest(files: DebugBundle.fileNames, now: date)
        XCTAssertEqual(manifest.files, DebugBundle.fileNames)
        XCTAssertFalse(manifest.version.isEmpty)
        XCTAssertFalse(manifest.ios.isEmpty)
        XCTAssertFalse(manifest.device.isEmpty)
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(DebugBundle.Manifest.self, from: data), manifest)
        let name = DebugBundle.fileName(build: "70", at: date)
        XCTAssertTrue(name.hasPrefix("Poki-Debug-70-") && name.hasSuffix(".zip"), name)
        for forbidden in ["memory", "chat", "screen", "pairing", "keychain"] {
            XCTAssertFalse(DebugBundle.fileNames.contains { $0.lowercased().contains(forbidden) }, forbidden)
        }
    }

    func testAFolderBecomesOneZip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("debug-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let zip = try DebugBundle.zipped(folder)
        let head = try FileHandle(forReadingFrom: zip).read(upToCount: 2)
        XCTAssertEqual(head, Data([0x50, 0x4B]), "a zip starts with PK")
    }
}
