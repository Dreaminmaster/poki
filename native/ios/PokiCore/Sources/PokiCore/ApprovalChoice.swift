import Foundation

/// How the owner answers a step the rules hold back that is not a payment, a deletion or Wallet:
/// in words in Poki's chat, on an Allow card, or not at all (the app's Approvals page).
public enum ApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case reply, confirm, off
    public var id: String { rawValue }
}

/// How readily the chat model lets such a step through before the owner is asked, least asking first.
public enum ApprovalLevel: String, CaseIterable, Identifiable, Sendable {
    case permissive, balanced, strict, everything
    public var id: String { rawValue }
}

/// The way of asking saved on the phone, from the keys each version of the app wrote. An update never
/// asks less than the version it replaces, and a value that cannot be read asks the most: With
/// Confirmation at Ask for Everything, an Allow card for every step.
public enum ApprovalChoice {
    /// This version's choice. 0.3.0 kept its own as "approvals.mode", which 0.3.1 ignored: those owners
    /// were asked as 0.3.1's switches said, and their 0.3.0 choice does not come back.
    public static let modeKey = "approvals.mode.v2"
    /// Saved with the way of asking here, and by 0.3.1's auto-classifier and 0.3.0 before that.
    public static let levelKey = "approvals.classifier.level"
    /// 0.3.1's two switches: Ask Me (on unless turned off) and the auto-classifier (a test, off
    /// unless turned on).
    public static let askKey = "approvals.ask"
    public static let classifierKey = "approvals.classifier"

    /// `saved` reads a key as UserDefaults stores it.
    public static func resolve(_ saved: (String) -> Any?) -> (mode: ApprovalMode, level: ApprovalLevel) {
        let level = saved(levelKey)
        if let mode = saved(modeKey) {
            guard let mode = (mode as? String).flatMap(ApprovalMode.init) else { return (.confirm, .everything) }
            return (mode, (level as? String).flatMap(ApprovalLevel.init) ?? .everything)
        }
        // 0.3.1 with the auto-classifier on: the model judged every step, at the sensitivity picked
        // there, Balanced until one was.
        if saved(classifierKey) as? Bool == true {
            guard let level else { return (.reply, .balanced) }
            return (.reply, (level as? String).flatMap(ApprovalLevel.init) ?? .everything)
        }
        // Otherwise 0.3.1 asked nothing with Ask Me off and the owner for every step with it on, whatever
        // sensitivity a classifier turned off again left saved.
        return (saved(askKey) as? Bool == false ? .off : .confirm, .everything)
    }
}
