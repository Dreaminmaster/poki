import Darwin
import Foundation
import XCTest
@testable import PokiSetup

@MainActor
final class AppModelTests: XCTestCase {
    /// Runs first (XCTest goes in name order): its helper exits when done, so the next test starts
    /// its own instead of reusing this one through Bridge.shared.
    func testAccountPageShowsSignInAgainWhenAnotherClientStoresIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-mac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logPath = dir.appendingPathComponent("commands.log").path
        let helperPath = dir.appendingPathComponent("fake-bridge.py").path
        let script = """
        #!/usr/bin/env python3
        import json, sys
        log_path = \(String(reflecting: logPath))
        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()
        send({"event": "ready", "data": {"version": "0.2.4"}})
        accounts = 0
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            req = json.loads(raw)
            cmd = req.get("cmd", "")
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(cmd + "\\n")
            if cmd == "account":
                accounts += 1
                stored = accounts > 1
                send({"id": req["id"], "ok": {
                    "signed_in": not stored,
                    "needs_reauth": stored,
                    "apple_id": "person@example.com",
                    "name": "Test Person",
                    "team_id": "TEAM1234",
                    "password_kept": True,
                    "anisette": {"kind": "system"},
                    "pending_factor": None,
                }})
                if stored:
                    sys.exit(0)
            elif cmd == "teams":
                send({"id": req["id"], "ok": [{"team_id": "TEAM1234", "name": "Test Person", "kind": "Individual", "is_free": True}]})
                # The CLI stores the sign-in-again state while the Account page is open.
                send({"event": "account_changed"})
            else:
                send({"id": req["id"], "ok": []})
        """
        try script.write(toFile: helperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)

        setenv("POKI_SETUP_BRIDGE", helperPath, 1)
        defer { unsetenv("POKI_SETUP_BRIDGE") }

        let model = AppModel()
        await model.refreshAccount()
        XCTAssertEqual(model.teams.count, 1)

        let deadline = Date().addingTimeInterval(5)
        while model.account?.signedIn != false, Date() < deadline {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.account?.signedIn, false, "the open page must stop showing the account as signed in")
        XCTAssertEqual(model.account?.needsReauth, true, "the open page must ask for a fresh sign-in")
        XCTAssertTrue(model.teams.isEmpty)
        let logged = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(logged, ["account", "teams", "account"], "only the account is read again, nothing asks Apple")
    }

    func testRateLimitedAccountSkipsBackgroundRenewDueAndTeamRefresh() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-mac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logPath = dir.appendingPathComponent("commands.log").path
        let helperPath = dir.appendingPathComponent("fake-bridge.py").path
        let script = """
        #!/usr/bin/env python3
        import json, sys
        log_path = \(String(reflecting: logPath))
        sys.stdout.write(json.dumps({"event": "ready", "data": {"version": "0.2.4"}}) + "\\n")
        sys.stdout.flush()
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            req = json.loads(raw)
            cmd = req.get("cmd", "")
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(cmd + "\\n")
            if cmd == "account":
                res = {
                    "signed_in": True,
                    "apple_id": "person@example.com",
                    "name": "Test Person",
                    "team_id": "TEAM1234",
                    "password_kept": True,
                    "anisette": {"kind": "system"},
                    "pending_factor": None,
                    "rate_limited": True,
                    "rate_limited_until": 4102444800,
                }
            else:
                res = []
            sys.stdout.write(json.dumps({"id": req["id"], "ok": res}) + "\\n")
            sys.stdout.flush()
        """
        try script.write(toFile: helperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)

        setenv("POKI_SETUP_BRIDGE", helperPath, 1)
        defer { unsetenv("POKI_SETUP_BRIDGE") }

        let model = AppModel()
        await model.refreshAccount()
        await model.renewDue()

        let logged = (try? String(contentsOfFile: logPath, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
        XCTAssertTrue(logged.contains("account"), "expected account state query, got: \(logged)")
        XCTAssertFalse(logged.contains("teams"), "rate-limited account must not auto-load teams, got: \(logged)")
        XCTAssertFalse(logged.contains("renew_due"), "rate-limited account must not run renew_due, got: \(logged)")
    }
}
