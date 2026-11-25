import Foundation
import UserNotifications

enum ApprovalNotice {
    static let allow = "approval.allow"
    static let deny = "approval.deny"
    static let stopAsking = "approval.stop"
}
struct ApprovalDecision {
    let approvalID: String
    let approved: Bool
    var stopAsking = false
    var waitForIslandCollapse = true
}
enum ApprovalIntentBridge {
    @MainActor static func submit(_ decision: ApprovalDecision) async {
        precondition(Thread.isMainThread)
        precondition(decision.approvalID == "test-approval")
        // Notifications do not originate from the Live Activity's Dynamic Island.
        precondition(!decision.waitForIslandCollapse)
    }
}
checkNotificationResponses(ApprovalNoticeDelegate.shared)
RunLoop.main.run()
