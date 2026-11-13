import UIKit
import XCTest
@testable import Poki

final class SetupSettingsTests: XCTestCase {
    func testSystemSetupStepsOpenSettingsRoot() {
        for step: SetupStep in [.runner, .developerMode, .pairing, .automation] {
            XCTAssertEqual(settingsURL(for: step)?.absoluteString, "App-prefs:", "\(step) must not open Poki's App permissions")
        }
    }

    func testBackgroundPermissionsStillOpenPokiSettings() {
        XCTAssertEqual(settingsURL(for: .background)?.absoluteString, UIApplication.openSettingsURLString)
    }

    func testDefaultDestinationRemainsPokiSettings() {
        XCTAssertEqual(settingsURL(for: nil)?.absoluteString, UIApplication.openSettingsURLString)
    }
}
