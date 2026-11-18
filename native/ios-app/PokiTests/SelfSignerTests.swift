import XCTest
@testable import Poki

@MainActor
private final class FakeSignerTransport {
    var statusValue: [String: Any]
    var latestValue: [String: Any]
    var prepareError: SignerError?
    var finishError: SignerError?
    var finishClearsPendingAndRequiresReauth = false
    var holdTeams = false
    private var heldTeams: [CheckedContinuation<Void, Never>] = []
    private(set) var ops: [String] = []

    init(
        signedIn: Bool = true,
        needsCode: Bool = false,
        rateLimited: Bool = false,
        latestVersion: String = "0.0.1",
        latestBuild: String = "1"
    ) {
        self.statusValue = [
            "signed_in": signedIn,
            "needs_code": needsCode,
            "rate_limited": rateLimited,
            "apple_id": "tester@example.com",
            "name": "Tester",
            "team_id": "TEAMID1234",
            "keeps_password": true,
            "anisette": "https://ani.example.com",
            "channel": "beta",
            "channels": [["id": "beta", "title": "Beta"]],
        ]
        self.latestValue = [
            "tag": "app-\(latestVersion)-beta.\(latestBuild)",
            "version": latestVersion,
            "build": latestBuild,
            "channel": "beta",
        ]
    }

    func releaseTeams() {
        let waiting = heldTeams
        heldTeams = []
        for continuation in waiting { continuation.resume() }
    }

    func send(_ request: [String: Any], _ progress: (@Sendable ([String: Any]) -> Void)?) async throws -> Data {
        let op = request["op"] as? String ?? ""
        ops.append(op)
        switch op {
        case "status":
            return try JSONSerialization.data(withJSONObject: ["v": statusValue])
        case "check_update":
            return try JSONSerialization.data(withJSONObject: ["v": latestValue])
        case "teams":
            if holdTeams {
                await withCheckedContinuation { heldTeams.append($0) }
            }
            return try JSONSerialization.data(withJSONObject: [
                "v": [["team_id": "TEAMID1234", "name": "Tester", "kind": "Individual", "is_free": true]],
            ])
        case "prepare":
            if let prepareError { throw prepareError }
            return try JSONSerialization.data(withJSONObject: [
                "v": [
                    "kind": request["kind"] as? String ?? "update",
                    "ipa": "/tmp/nonexistent-poki.ipa",
                    "bundle_id": "nz.zheha.poki.TEAMID1234",
                    "version": latestValue["version"] ?? "9.9.9",
                    "build": latestValue["build"] ?? "999",
                    "tag": latestValue["tag"] ?? "app-9.9.9",
                    "team_name": "Tester",
                    "team_is_free": true,
                    "profile_expires_at": 4_102_444_800,
                    "prepared_at": 1_700_000_000,
                ],
            ])
        case "sign_in":
            statusValue["needs_code"] = false
            statusValue["needs_reauth"] = false
            statusValue["signed_in"] = true
            return try JSONSerialization.data(withJSONObject: ["v": ["needs_code": false]])
        case "finish_sign_in":
            if let finishError {
                if finishClearsPendingAndRequiresReauth {
                    statusValue["needs_code"] = false
                    statusValue["signed_in"] = false
                    statusValue["needs_reauth"] = true
                }
                throw finishError
            }
            statusValue["needs_code"] = false
            statusValue["needs_reauth"] = false
            statusValue["signed_in"] = true
            return try JSONSerialization.data(withJSONObject: ["v": [:]])
        case "cancel_sign_in":
            statusValue["needs_code"] = false
            return try JSONSerialization.data(withJSONObject: ["v": [:]])
        case "resend_code":
            let next = Int64(Date().timeIntervalSince1970) + 60
            statusValue["resend_available_at"] = next
            return try JSONSerialization.data(withJSONObject: ["v": ["resend_available_at": next]])
        default:
            return try JSONSerialization.data(withJSONObject: ["v": NSNull()])
        }
    }
}

@MainActor
final class SelfSignerTests: XCTestCase {
    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func testMaintainThrottlesChannelChecksEvenWhenSignedInWithLoopback() async {
        let fake = FakeSignerTransport(signedIn: true, needsCode: false, latestVersion: "0.0.1", latestBuild: "1")
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        signer.phone = { ["host": "10.7.0.1"] }
        await signer.reload()

        signer.maintain()
        await settle()
        XCTAssertEqual(fake.ops.filter { $0 == "check_update" }.count, 1)

        for _ in 0..<5 {
            signer.maintain()
            await settle()
        }
        XCTAssertEqual(fake.ops.filter { $0 == "check_update" }.count, 1, "repeated foreground or loopback transitions within 3 hours must not re-query the channel")
    }

    func testWaitingForVerificationCodeBlocksBackgroundSigningAndTeamLoads() async {
        let fake = FakeSignerTransport(signedIn: true, needsCode: true, latestVersion: "99.0.0", latestBuild: "999")
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        signer.phone = { ["host": "10.7.0.1"] }
        await signer.reload()

        signer.maintain()
        await settle()
        _ = await signer.checkLatest()
        await signer.loadTeams()

        XCTAssertFalse(fake.ops.contains("prepare"), "auto-prepare must stay quiet until the user enters the verification code")
        XCTAssertFalse(fake.ops.contains("teams"), "loading teams must not run while a verification code is pending")
    }

    func testRateLimitedAccountBlocksBackgroundSigningAndFailedAutoPrepareBacksOff() async {
        let fake = FakeSignerTransport(signedIn: true, needsCode: false, rateLimited: true, latestVersion: "99.0.0", latestBuild: "999")
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        signer.phone = { ["host": "10.7.0.1"] }
        await signer.reload()

        signer.maintain()
        await settle()
        _ = await signer.checkLatest()
        await signer.loadTeams()
        XCTAssertFalse(fake.ops.contains("prepare"))
        XCTAssertFalse(fake.ops.contains("teams"))

        fake.statusValue["rate_limited"] = false
        fake.prepareError = SignerError(message: "Apple has had too many sign-in attempts or codes for this Apple Account.", code: "apple_account_limit")
        await signer.reload()

        _ = await signer.checkLatest()
        XCTAssertEqual(fake.ops.filter { $0 == "prepare" }.count, 1)

        _ = await signer.checkLatest()
        signer.maintain()
        await settle()
        XCTAssertEqual(fake.ops.filter { $0 == "prepare" }.count, 1, "failed automatic prepare must back off instead of retrying on every foreground wake")
    }

    func testConcurrentLoadTeamsCoalescesIntoSingleBridgeCall() async {
        let fake = FakeSignerTransport(signedIn: true, needsCode: false)
        fake.holdTeams = true
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        await signer.reload()

        let first = Task { await signer.loadTeams() }
        await settle()
        let second = Task { await signer.loadTeams() }
        await settle()
        fake.releaseTeams()
        await first.value
        await second.value

        XCTAssertEqual(fake.ops.filter { $0 == "teams" }.count, 1)
    }

    func testCancelSignInClearsPendingAndAllowsSwitchingAppleAccount() async {
        let fake = FakeSignerTransport(signedIn: false, needsCode: true)
        fake.finishError = SignerError(
            message: "That verification code is incorrect. Check the 6-digit code and enter the newest code you received.",
            code: "needs_person"
        )
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        await signer.reload()
        signer.presentCodeSheet()

        await signer.finishSignIn(code: "000000")
        XCTAssertTrue(signer.needsCode)
        XCTAssertNotNil(signer.lastError)

        await signer.cancelSignIn()
        XCTAssertTrue(fake.ops.contains("cancel_sign_in"))
        XCTAssertFalse(signer.needsCode, "cancelling sign-in must clear needsCode so user can switch Apple Accounts")
        XCTAssertFalse(signer.signedIn)
        XCTAssertFalse(signer.needsCodeSheet)
        XCTAssertNil(signer.lastError)
    }

    func testResendCodeEnforcesSixtySecondCooldownAndRateLimitWaitDisplay() async {
        let fake = FakeSignerTransport(signedIn: false, needsCode: true)
        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        await signer.reload()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(signer.canResendCode(at: start))

        await signer.resendCode(now: start)
        XCTAssertEqual(fake.ops.filter { $0 == "resend_code" }.count, 1)

        fake.statusValue["resend_available_at"] = Int64(start.timeIntervalSince1970) + 60
        await signer.reload()

        let tenSecondsLater = start.addingTimeInterval(10)
        XCTAssertFalse(signer.canResendCode(at: tenSecondsLater))
        XCTAssertEqual(signer.resendCooldownSeconds(at: tenSecondsLater), 50)
        await signer.resendCode(now: tenSecondsLater)
        XCTAssertEqual(fake.ops.filter { $0 == "resend_code" }.count, 1, "must not resend during 60s cooldown")

        fake.statusValue["rate_limited"] = true
        fake.statusValue["rate_limited_until"] = Int64(start.timeIntervalSince1970) + 2700
        await signer.reload()
        XCTAssertFalse(signer.canResendCode(at: start.addingTimeInterval(120)))
        let label = signer.resendButtonTitle(at: start)
        XCTAssertTrue(label.contains("45"), "rate-limited resend button must display remaining wait minutes, got: \(label)")
    }

    func testLocalizedWrongAndExpiredCodeMessagesAreDistinct() {
        let previous = AppLocalization.shared.preference
        defer { AppLocalization.shared.preference = previous }

        let wrong = "That verification code is incorrect. Check the 6-digit code and enter the newest code you received."
        let expired = "That verification code has expired. Enter the newest 6-digit code, or request a new code."
        let incomplete = "Apple verified the code, but did not finish opening the session. Sign in again to start a fresh session."

        AppLocalization.shared.preference = "zh-Hans"
        let zhWrong = SelfSigner.localizedErrorText(wrong)
        let zhExpired = SelfSigner.localizedErrorText(expired)
        let zhIncomplete = SelfSigner.localizedErrorText(incomplete)
        XCTAssertTrue(zhWrong.contains("验证码不对"), zhWrong)
        XCTAssertFalse(zhWrong.contains("已过期"), zhWrong)
        XCTAssertTrue(zhExpired.contains("已过期") && zhExpired.contains("最新"), zhExpired)
        XCTAssertTrue(zhIncomplete.contains("重新登录"), zhIncomplete)
        XCTAssertNotEqual(zhWrong, zhExpired)
        XCTAssertNotEqual(zhWrong, zhIncomplete)
    }

    func testIncompleteSessionAfterVerificationRequiresManualSignInAndBlocksTeamsAndRenewal() async {
        let fake = FakeSignerTransport(signedIn: true, needsCode: true, latestVersion: "99.0.0", latestBuild: "999")
        fake.finishError = SignerError(
            message: "Apple verified the code, but did not finish opening the session. Sign in again to start a fresh session.",
            code: "needs_person"
        )
        fake.finishClearsPendingAndRequiresReauth = true

        let signer = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        signer.phone = { ["host": "10.7.0.1"] }
        await signer.reload()
        signer.presentCodeSheet()

        await signer.finishSignIn(code: "654321")
        await signer.loadTeams()
        signer.maintain()
        await settle()
        _ = await signer.checkLatest()

        XCTAssertEqual(fake.ops.filter { $0 == "teams" }.count, 0, "loadTeams must not run after keyless 409 verification")
        XCTAssertEqual(fake.ops.filter { $0 == "prepare" }.count, 0, "background renewal must not prepare after keyless 409 verification")
        XCTAssertFalse(signer.signedIn, "UI must not present account as signed in when manual re-login is required")
        XCTAssertFalse(signer.needsCodeSheet, "consumed verification code sheet must close")
        XCTAssertTrue(signer.lastError?.lowercased().contains("sign in again") == true)

        let relaunched = SelfSigner(transport: { req, prog in try await fake.send(req, prog) })
        relaunched.phone = { ["host": "10.7.0.1"] }
        await relaunched.reload()
        await relaunched.loadTeams()
        relaunched.maintain()
        await settle()

        XCTAssertFalse(relaunched.signedIn, "relaunched UI must still treat account as requiring manual sign-in")
        XCTAssertEqual(fake.ops.filter { $0 == "teams" }.count, 0)
        XCTAssertEqual(fake.ops.filter { $0 == "prepare" }.count, 0)

        await relaunched.signIn(appleID: "tester@example.com", password: "pw", keepPassword: true)
        XCTAssertTrue(relaunched.signedIn)
        XCTAssertEqual(fake.ops.filter { $0 == "teams" }.count, 1)
    }
}
