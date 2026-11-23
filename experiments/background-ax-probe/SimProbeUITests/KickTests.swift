import XCTest

// Layout kick, second round: the pending pop sits on a screen that now has a table. Scroll actions on the table
// or its rows may lay out the view tree and let the pop finish while the app stays in the background.
extension SimFixtureTests {
    func testKICK_background() {
        layoutCase("table: none") { "-" }
        layoutCase("2003 on DetailRow 3") { self.act(self.find(self.snap(), { $0.identifier == "DetailRow 3" }), 2003) }
        layoutCase("2003 on last row in tree") {
            var last: XCUIElementSnapshot?
            func w(_ e: XCUIElementSnapshot) { if e.identifier.hasPrefix("DetailRow ") { last = e }; e.children.forEach(w) }
            if let app = self.snap() { w(app) }
            return (last?.identifier ?? "none") + " " + self.act(last, 2003)
        }
        layoutCase("2006 on table") { self.act(self.find(self.snap(), { $0.identifier == "cov.detailtable" }), 2006) }
        layoutCase("2007 on table") { self.act(self.find(self.snap(), { $0.identifier == "cov.detailtable" }), 2007) }
        layoutCase("2003 on table") { self.act(self.find(self.snap(), { $0.identifier == "cov.detailtable" }), 2003) }
        layoutCase("5021 on table") {
            guard let t = self.find(self.snap(), { $0.identifier == "cov.detailtable" }) else { return "no table" }
            var err: NSString?
            return PBHelper.pressSnapshot(t, action: 5021, value: NSNumber(value: 1), error: &err) ? "ok" : "fail"
        }
        say("KICK | front after: \(frontSummary())")
    }
}
