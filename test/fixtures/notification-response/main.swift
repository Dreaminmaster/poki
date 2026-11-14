import Foundation
import UserNotifications

enum ApprovalNotice {
    static let allow = "approval.allow"
    static let deny = "approval.deny"
}
struct ApprovalDecision {
    let approvalID: String
    let approved: Bool
}
enum ApprovalIntentBridge {
    @MainActor static func submit(_ decision: ApprovalDecision) {
        precondition(Thread.isMainThread)
        precondition(decision.approvalID == "test-approval")
    }
}
checkNotificationResponses(ApprovalNoticeDelegate.shared)
RunLoop.main.run()
