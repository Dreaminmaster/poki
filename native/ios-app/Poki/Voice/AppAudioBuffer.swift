import Foundation

final class AppAudioBuffer: @unchecked Sendable {
    static let sampleRate = 16_000
    static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    static let seconds = 60
    static let capacity = seconds * bytesPerSecond

    struct Clock {
        let now: @Sendable () -> TimeInterval
        let schedule: @Sendable (TimeInterval, DispatchWorkItem) -> Void

        static let system = Clock(now: { ProcessInfo.processInfo.systemUptime }, schedule: { deadline, item in
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        })
    }

    private struct Transcription: Sendable {
        let input: AppAudioInput
        let cancelTask: @Sendable () -> Void

        func cancel() {
            input.finish(cancel: true)
            cancelTask()
        }
    }

    private let lock = NSLock()
    private let clock: Clock
    private var chunks: [AppAudioInput.Chunk] = []
    private var byteCount = 0
    private var active = true
    private var expiry: (deadline: TimeInterval, item: DispatchWorkItem)?
    private var transcription: Transcription?

    init(clock: Clock = .system) { self.clock = clock }

    var isActive: Bool { lock.withLock { active } }

    func append(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= Self.bytesPerSecond else { return }
        lock.withLock {
            guard active else { return }
            let time = clock.now()
            expire(through: time - Double(Self.seconds))
            while byteCount + pcm.count > Self.capacity { removeOldest() }
            let last = chunks.count - 1
            if last >= 0, time - chunks[last].start < 1,
               chunks[last].pcm.count + pcm.count <= Self.bytesPerSecond {
                chunks[last].pcm.append(pcm)
            } else {
                chunks.append(.init(start: time, pcm: pcm))
            }
            byteCount += pcm.count
            scheduleExpiry()
        }
    }

    func transcribe(_ recognize: @escaping @Sendable (AppAudioInput) async throws -> String) async throws -> String? {
        let work = lock.withLock { () -> (Transcription, AsyncThrowingStream<String, Error>)? in
            guard active, transcription == nil else { return nil }
            expire(through: clock.now() - Double(Self.seconds))
            scheduleExpiry()
            guard !chunks.isEmpty else { return nil }
            let input = AppAudioInput(chunks)
            // Stop can unblock the caller while the system speech engine is still preparing.
            let (results, result) = AsyncThrowingStream<String, Error>.makeStream()
            let task = Task {
                do {
                    let text = try await recognize(input)
                    try Task.checkCancellation()
                    result.yield(text)
                    result.finish()
                } catch {
                    result.finish(throwing: error)
                }
            }
            let current = Transcription(input: input, cancelTask: {
                result.finish()
                task.cancel()
            })
            transcription = current
            return (current, results)
        }
        guard let (current, results) = work else { return nil }
        defer {
            current.input.finish(cancel: false)
            lock.withLock {
                if transcription?.input === current.input {
                    transcription = nil
                    scheduleExpiry()
                }
            }
        }
        let text = try await withTaskCancellationHandler {
            try await results.first(where: { _ in true })
        } onCancel: {
            current.cancel()
        }
        return !Task.isCancelled && current.input.isActive && isActive ? text : nil
    }

    func stop() {
        let current = lock.withLock {
            active = false
            chunks.removeAll()
            byteCount = 0
            expiry?.item.cancel()
            expiry = nil
            defer { transcription = nil }
            return transcription
        }
        current?.cancel()
    }

    private func expire(through cutoff: TimeInterval) {
        while let first = chunks.first, first.start <= cutoff { removeOldest() }
        transcription?.input.expire(through: cutoff)
    }

    private func removeOldest() {
        byteCount -= chunks.removeFirst().pcm.count
    }

    private func scheduleExpiry() {
        let oldest = [chunks.first?.start, transcription?.input.oldest].compactMap { $0 }.min()
        let deadline = oldest.map { $0 + Double(Self.seconds) }
        guard deadline != expiry?.deadline else { return }
        expiry?.item.cancel()
        expiry = nil
        if let deadline {
            let item = DispatchWorkItem { [weak self] in self?.expire(at: deadline) }
            expiry = (deadline, item)
            clock.schedule(deadline, item)
        }
    }

    private func expire(at deadline: TimeInterval) {
        lock.withLock {
            guard expiry?.deadline == deadline else { return }
            expiry = nil
            expire(through: clock.now() - Double(Self.seconds))
            scheduleExpiry()
        }
    }
}
