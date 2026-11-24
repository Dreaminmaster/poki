import Foundation

final class ChatStepTiming: @unchecked Sendable {
    @TaskLocal static var current: ChatStepTiming?

    private let taskLabel: String
    private let lock = NSLock()
    private var turn = 0
    private var action = 0
    private var hasOutput = false
    private var hasText = false

    init(session: String, task: UUID, flow: String = "chat") {
        let taskID = task.uuidString.lowercased()
        let sessionID = UUID(uuidString: session)?.uuidString.lowercased() ?? taskID
        taskLabel = "session=\(sessionID) task=\(taskID) flow=\(flow)"
    }

    func beginTurn() {
        lock.withLock {
            turn += 1
            action = 0
            hasOutput = false
            hasText = false
        }
    }

    func nextAction() -> Int {
        lock.withLock {
            action += 1
            return action
        }
    }

    enum Output: String { case text, reasoning, tool }

    func firstOutput(_ output: Output, boundary: String = "stream") {
        let (firstOutput, firstText) = lock.withLock {
            let firstOutput = !hasOutput
            let firstText = output == .text && !hasText
            hasOutput = true
            hasText = hasText || output == .text
            return (firstOutput, firstText)
        }
        if firstOutput {
            record("model_first_output", "kind=\(output.rawValue) boundary=\(boundary)")
        } else if firstText {
            record("model_first_text", "boundary=\(boundary)")
        }
    }

    func record(_ event: String, _ fields: String) {
        let time = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let turn = lock.withLock { self.turn }
        let line = "\(taskLabel) turn=\(turn) t_ms=\(time) event=\(event) \(fields)"
        DispatchQueue.main.async { AppLog.shared.add("chat-timing", line) }
    }
}
