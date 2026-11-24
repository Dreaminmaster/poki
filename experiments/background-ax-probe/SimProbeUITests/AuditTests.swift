import XCTest

// The pending pop needs a layout pass. XCTest's public accessibility audit runs in the app through
// accessibility and lays the app out (dynamic type and clipping checks). This checks whether it runs against a
// background app, whether the front app stays in front, and whether the pending pop completes.
extension SimFixtureTests {
    func auditCase(_ name: String, _ types: XCUIAccessibilityAuditType) {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        let r0 = barEscape(); usleep(1_500_000); navDump("\(name) | after 2013 \(r0)")
        var n = 0; var res = "ok"
        do { try fixture.performAccessibilityAudit(for: types) { _ in n += 1; return true } }
        catch { res = "threw \(String(describing: error).prefix(160))" }
        navDump("\(name) | after audit \(res) issues \(n) state \(fixture.state.rawValue)")
        say("AUDIT | \(name) | front: \(frontSummary())")
        sleep(3); navDump("\(name) | +3s")
    }
    func testAUDIT_background() {
        continueAfterFailure = true
        auditCase("dynamicType", .dynamicType)
        auditCase("textClipped", .textClipped)
        auditCase("hitRegion", .hitRegion)
        auditCase("elementDetection", .elementDetection)
        auditCase("all", .all)
    }
}
