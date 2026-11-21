import Foundation

final class AppAudioBuffer: @unchecked Sendable {
    static let sampleRate = 16_000
    static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    static let seconds = 60
    static let capacity = seconds * bytesPerSecond

    private struct Chunk {
        let start: TimeInterval
        var pcm: Data
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var byteCount = 0
    private var active = true

    var isActive: Bool { lock.withLock { active } }

    func append(_ pcm: Data, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !pcm.isEmpty, pcm.count <= Self.bytesPerSecond else { return }
        lock.withLock {
            guard active else { return }
            while let first = chunks.first,
                  time - first.start >= Double(Self.seconds) || byteCount + pcm.count > Self.capacity {
                byteCount -= first.pcm.count
                chunks.removeFirst()
            }
            let last = chunks.count - 1
            if last >= 0, time - chunks[last].start < 1 {
                chunks[last].pcm.append(pcm)
            } else {
                chunks.append(Chunk(start: time, pcm: pcm))
            }
            byteCount += pcm.count
        }
    }

    func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data? {
        lock.withLock {
            guard active else { return nil }
            return chunks.reduce(into: Data()) { pcm, chunk in
                if time - chunk.start < Double(Self.seconds) { pcm.append(chunk.pcm) }
            }
        }
    }

    func stop() {
        lock.withLock {
            active = false
            chunks.removeAll()
            byteCount = 0
        }
    }
}
