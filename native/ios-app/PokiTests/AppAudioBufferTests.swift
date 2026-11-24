import XCTest
@testable import Poki

final class AppAudioBufferTests: XCTestCase {
    func testOnlyRecentAudioIsReadableAndStoppingDiscardsIt() async throws {
        let clock = AudioTestClock()
        let buffer = AppAudioBuffer(clock: clock.value)
        for second in 0...60 {
            clock.advance(to: Double(second))
            buffer.append(Data([UInt8(second), 0]))
        }

        let expected = Data((1...60).flatMap { [UInt8($0), 0] }).base64EncodedString()
        let recent = try await buffer.transcribe(Self.read)
        XCTAssertEqual(recent, expected)

        clock.advance(to: 120)
        let expired = try await buffer.transcribe(Self.read)
        XCTAssertNil(expired)

        buffer.stop()
        buffer.append(Data([1, 0]))
        let stopped = try await buffer.transcribe(Self.read)
        XCTAssertNil(stopped)
    }

    private static let read: @Sendable (AppAudioInput) async throws -> String = { input in
        var pcm = Data()
        while let chunk = input.next({ $0 }) { pcm.append(chunk) }
        return pcm.base64EncodedString()
    }

    func testExpiredAudioReleasesItsStorageWithoutAnotherSampleOrRead() {
        let clock = AudioTestClock()
        let buffer = AppAudioBuffer(clock: clock.value)
        let release = AudioTestSignal()
        buffer.append(trackedAudio(release))
        XCTAssertFalse(release.observed)

        clock.advance(to: 59)
        XCTAssertFalse(release.observed)
        clock.advance(to: 60)
        XCTAssertTrue(release.observed)
    }

    func testStopReleasesTheTranscribingAudioAndCancelsRecognition() async throws {
        let buffer = AppAudioBuffer()
        let release = AudioTestSignal()
        let recognizer = SuspendedAudioRecognition()
        buffer.append(trackedAudio(release))

        let answer = Task { try await buffer.transcribe { input in await recognizer.recognize(input) } }
        await recognizer.waitUntilStarted()
        XCTAssertFalse(release.observed)

        buffer.stop()
        XCTAssertTrue(release.observed)
        XCTAssertTrue(recognizer.cancellation.observed)

        await recognizer.finish()
        let result = try await answer.value
        XCTAssertNil(result)
    }
}

private final class AudioTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    var observed: Bool { lock.withLock { received } }

    func signal() { lock.withLock { received = true } }
}

private func trackedAudio(_ release: AudioTestSignal) -> Data {
    let size = 32_000
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    bytes.initializeMemory(as: UInt8.self, repeating: 7, count: size)
    return Data(bytesNoCopy: bytes, count: size, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        release.signal()
    })
}

private final class AudioTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var work: [(TimeInterval, DispatchWorkItem)] = []

    var value: AppAudioBuffer.Clock {
        AppAudioBuffer.Clock(now: { self.lock.withLock { self.time } }, schedule: { deadline, item in
            self.lock.withLock { self.work.append((deadline, item)) }
        })
    }

    func advance(to time: TimeInterval) {
        let due = lock.withLock {
            self.time = time
            let due = work.filter { $0.0 <= time }
            work.removeAll { $0.0 <= time }
            return due
        }
        due.forEach { $0.1.perform() }
    }
}

private actor SuspendedAudioRecognition {
    nonisolated let cancellation = AudioTestSignal()
    private var began: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?

    func recognize(_ input: AppAudioInput) async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                response = continuation
                began?.resume()
                began = nil
            }
        } onCancel: {
            cancellation.signal()
        }
        withExtendedLifetime(input) {}
        return "Late transcript"
    }

    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { began = $0 }
    }

    func finish() {
        response?.resume()
        response = nil
    }
}
