import XCTest
@testable import Poki

/// A free Apple Account's install asks for the Apple Account sign-in right after setup (issue #740).
final class RenewSignInTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_795_000_000)

    func testSevenDayProfileIsFree() {
        let profile: [String: Any] = ["CreationDate": created, "ExpirationDate": created.addingTimeInterval(7 * 86_400)]
        XCTAssertTrue(SelfSigner.profileIsFree(profile))
    }

    func testYearLongProfileIsPaid() {
        let profile: [String: Any] = ["CreationDate": created, "ExpirationDate": created.addingTimeInterval(365 * 86_400)]
        XCTAssertFalse(SelfSigner.profileIsFree(profile))
    }

    func testEnterpriseAndIncompleteProfilesAreNotFree() {
        let enterprise: [String: Any] = ["CreationDate": created, "ExpirationDate": created.addingTimeInterval(86_400), "ProvisionsAllDevices": true]
        XCTAssertFalse(SelfSigner.profileIsFree(enterprise))
        XCTAssertFalse(SelfSigner.profileIsFree(["ExpirationDate": created]))
    }

    func testProfilePlistReadsInsideTheEnvelope() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CreationDate": created, "ExpirationDate": created.addingTimeInterval(6 * 86_400)],
                                                       format: .xml, options: 0)
        let envelope = Data([0x30, 0x82, 0x01, 0x00]) + plist + Data([0xA0, 0x00])
        let profile = try XCTUnwrap(SelfSigner.profilePlist(envelope))
        XCTAssertTrue(SelfSigner.profileIsFree(profile))
    }

    func testAsksOnceAfterSetupForAFreeInstallWithoutSignIn() {
        let expiry = created.addingTimeInterval(7 * 86_400)
        func ask(free: Bool = true, needs: Bool = true, known: Bool = true, after: Bool = true, askedFor: Double? = nil) -> Bool {
            RenewSignIn.shouldAsk(freeSigning: free, needsAccount: needs, statusKnown: known, afterSetup: after, expiry: expiry, askedFor: askedFor)
        }
        XCTAssertTrue(ask())
        XCTAssertFalse(ask(free: false), "a paid team's install never asks")
        XCTAssertFalse(ask(needs: false), "already signed in")
        XCTAssertFalse(ask(known: false), "the signer has not said yet whether it is signed in")
        XCTAssertFalse(ask(after: false), "only right after setup")
        XCTAssertFalse(ask(askedFor: expiry.timeIntervalSince1970), "asked already for this install")
        XCTAssertTrue(ask(askedFor: expiry.timeIntervalSince1970 - 86_400), "a new install asks again")
    }

    func testMarkAskedRecordsThisInstall() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RenewSignInTests"))
        defer { defaults.removePersistentDomain(forName: "RenewSignInTests") }
        let expiry = created.addingTimeInterval(7 * 86_400)
        XCTAssertNil(RenewSignIn.askedFor(defaults))
        RenewSignIn.markAsked(expiry: expiry, defaults: defaults)
        XCTAssertFalse(RenewSignIn.shouldAsk(freeSigning: true, needsAccount: true, statusKnown: true, afterSetup: true,
                                             expiry: expiry, askedFor: RenewSignIn.askedFor(defaults)))
    }

    @MainActor func testStartFlowEndsWithTheAppleAccountOnlyForFreeSigning() {
        XCTAssertEqual(SetupItem.all(freeSigning: true).last, .appleAccount)
        XCTAssertFalse(SetupItem.all(freeSigning: false).contains(.appleAccount))
    }
}
