import XCTest
@testable import PokiCore

/// The way of asking an owner finds after updating over 0.3.1 (752), for everything the phone can hold.
/// 0.3.1 asked the owner for every message, call and password unless Ask Me was off (nothing was
/// asked) or the auto-classifier on (the model judged, at the sensitivity picked for it, Balanced
/// until one was). An update must not ask less, and a value that cannot be read asks the most.
final class ApprovalChoiceTests: XCTestCase {
    /// How a message, a call or a password is asked about in Poki's own chat, least first: not at all,
    /// by the model at a sensitivity (its index, least asking first), or on the owner's card every time.
    enum Asking: Comparable { case nothing, model(Int), owner }

    static func asking(_ mode: ApprovalMode, _ level: ApprovalLevel) -> Asking {
        switch (mode, level) {
        case (.off, _): .nothing
        case (.confirm, .everything): .owner
        case (_, .permissive): .model(0)
        case (_, .balanced): .model(1)
        case (_, .strict): .model(2)
        case (_, .everything): .model(3)
        }
    }

    /// 0.3.1 as its code reads the same keys: `bool(forKey:)` for the classifier, Ask Me on unless it
    /// holds false, and the classifier's three sensitivities with Balanced for anything else.
    static func asked752(ask: Bool?, classifier: Bool?, level: String?) -> Asking {
        if classifier == true { return .model(["permissive": 0, "balanced": 1, "strict": 2][level ?? ""] ?? 1) }
        return ask == false ? .nothing : .owner
    }

    func testAnUpdateOver752NeverAsksLess() {
        for ask in [nil, true, false] as [Bool?] {
            for classifier in [nil, true, false] as [Bool?] {
                for level in [nil, "permissive", "balanced", "strict", "everything", "loud"] as [String?] {
                    // What 0.3.0 saved, which 0.3.1 ignored.
                    for left in [nil, "reply", "confirm", "off"] as [String?] {
                        var saved: [String: Any] = [:]
                        saved["approvals.ask"] = ask
                        saved["approvals.classifier"] = classifier
                        saved["approvals.classifier.level"] = level
                        saved["approvals.mode"] = left
                        let now = ApprovalChoice.resolve { saved[$0] }
                        let before = Self.asked752(ask: ask, classifier: classifier, level: level)
                        XCTAssertGreaterThanOrEqual(Self.asking(now.mode, now.level), before, "ask \(ask.map(String.init) ?? "unset"), classifier \(classifier.map(String.init) ?? "unset"), sensitivity \(level ?? "unset"), 0.3.0's choice \(left ?? "unset"): \(now)")
                    }
                }
            }
        }
    }

    func testWhereEachOwnerLands() {
        let rows: [(name: String, saved: [String: Any], mode: ApprovalMode, level: ApprovalLevel)] = [
            ("never chose", [:], .confirm, .everything),
            ("turned Ask Me off", ["approvals.ask": false], .off, .everything),
            ("turned the classifier on", ["approvals.classifier": true], .reply, .balanced),
            ("turned the classifier on at Strict", ["approvals.ask": true, "approvals.classifier": true, "approvals.classifier.level": "strict"], .reply, .strict),
            ("tried the classifier at Strict, then turned it off", ["approvals.ask": true, "approvals.classifier": false, "approvals.classifier.level": "strict"], .confirm, .everything),
            ("chose in 0.3.0, which 0.3.1 ignored", ["approvals.mode": "reply", "approvals.classifier.level": "permissive"], .confirm, .everything),
            ("a sensitivity nobody knows, classifier on", ["approvals.classifier": true, "approvals.classifier.level": "loud"], .reply, .everything),
            ("chose here", [ApprovalChoice.modeKey: "reply", "approvals.classifier.level": "strict"], .reply, .strict),
            ("chose Never Ask here", [ApprovalChoice.modeKey: "off", "approvals.ask": true], .off, .everything),
            ("a way of asking nobody knows", [ApprovalChoice.modeKey: "sometimes", "approvals.classifier.level": "permissive", "approvals.ask": false], .confirm, .everything),
        ]
        for row in rows {
            let now = ApprovalChoice.resolve { row.saved[$0] }
            XCTAssertEqual(now.mode, row.mode, row.name)
            XCTAssertEqual(now.level, row.level, row.name)
        }
    }
}
