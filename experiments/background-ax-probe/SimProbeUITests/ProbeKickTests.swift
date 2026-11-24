import XCTest

extension SimFixtureTests {
    func kickProbe(_ mode: String) {
        background = true
        fixture.launchArguments = ["-coverage", "-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES", "-kick", mode]
        fixture.launch()
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        fixture.descendants(matching: .any)["cov.push"].firstMatch.tap(); sleep(1)
        _ = PBHelper.requestBackgroundAssertion(forPID: pid); settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10)
        usleep(800_000)
        let r = barEscape()
        say("PROBE | \(mode) | 2013 \(r)")
        var last = ""
        for i in 0..<14 {
            let e = lastEvent()
            if e != last { say("PROBE | \(mode) | +\(i)s | \(e) | nav \(navTitle())"); last = e }
            sleep(1)
        }
        navDump("probe \(mode) end")
    }
    func testPROBEKICK_background() {
        for m in ["none", "navView", "navBar", "table", "window", "flush", "needs"] { kickProbe(m) }
        say("PROBE | front after: \(frontSummary())")
    }
}
