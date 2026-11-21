import Foundation

final class AppAudioInput: @unchecked Sendable {
    struct Chunk {
        let start: TimeInterval
        var pcm: Data
    }

    private let lock = NSLock()
    private var chunks: [Chunk]
    private var active = true
    private var cancelRecognition: (@Sendable () -> Void)?

    init(_ chunks: [Chunk]) { self.chunks = chunks }

    var isActive: Bool { lock.withLock { active } }
    var oldest: TimeInterval? { lock.withLock { chunks.first?.start } }

    func expire(through cutoff: TimeInterval) {
        lock.withLock { chunks.removeAll { $0.start <= cutoff } }
    }

    func next<Value>(_ make: (Data) throws -> Value) rethrows -> Value? {
        try lock.withLock {
            guard active, !chunks.isEmpty else { return nil }
            return try make(chunks.removeFirst().pcm)
        }
    }

    func onCancel(_ cancel: @escaping @Sendable () -> Void) {
        let stopped = lock.withLock {
            guard active else { return true }
            cancelRecognition = cancel
            return false
        }
        if stopped { cancel() }
    }

    func finish(cancel: Bool) {
        let action = lock.withLock {
            active = false
            chunks.removeAll()
            defer { cancelRecognition = nil }
            return cancelRecognition
        }
        if cancel { action?() }
    }
}
