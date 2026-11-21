#if os(iOS) && canImport(ScreenCaptureKit)
import AVFoundation
import Observation
import ScreenCaptureKit

@available(iOS 27, *)
@MainActor
@Observable
final class AppAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    static let shared = AppAudioCapture()

    private struct Capture {
        let stream: SCStream
        let output: AudioOutput
    }

    private enum State {
        case idle, choosing, starting(Capture), running(Capture), stopping(Capture), failed

        var capture: Capture? {
            switch self {
            case .starting(let capture), .running(let capture), .stopping(let capture): capture
            default: nil
            }
        }
    }

    private var state = State.idle

    var isTransitioning: Bool {
        switch state {
        case .choosing, .starting, .stopping: true
        default: false
        }
    }

    var didFail: Bool { if case .failed = state { true } else { false } }

    var buffer: AppAudioBuffer? {
        guard case .running(let capture) = state else { return nil }
        return capture.output.buffer
    }

    func choose() {
        guard !isTransitioning, buffer == nil else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { state = .failed; return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        state = .choosing
        picker.isActive = true
        picker.present(using: .display)
    }

    func stop() {
        guard case .running(let capture) = state else { return }
        capture.output.buffer.stop()
        state = .stopping(capture)
        Task {
            do {
                try await capture.stream.stopCapture()
                if state.capture?.stream === capture.stream { finish(.idle) }
            } catch {
                if state.capture?.stream === capture.stream { finish(.failed) }
            }
        }
    }

    private func start(_ filter: SCContentFilter) async {
        guard case .choosing = state else { return }
        guard filter.style == .display else { finish(.failed); return }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = AppAudioBuffer.sampleRate
        config.channelCount = 1
        let output = AudioOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let capture = Capture(stream: stream, output: output)
        state = .starting(capture)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            if state.capture?.stream === stream { state = .running(capture) }
        } catch {
            if state.capture?.stream === stream { finish(.failed) }
        }
    }

    private func finish(_ next: State) {
        state.capture?.output.buffer.stop()
        state = next
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            if case .choosing = state { finish(.idle) }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in await start(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            if case .choosing = state { finish(.failed) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard state.capture?.stream === stream else { return }
            let expected = (error as? SCStreamError)?.code == .userStopped
            if case .stopping = state { finish(.idle) }
            else { finish(expected ? .idle : .failed) }
        }
    }

    private final class AudioOutput: NSObject, SCStreamOutput {
        let queue = DispatchQueue(label: "Poki.AppAudioCapture")
        let buffer = AppAudioBuffer()
        private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AppAudioBuffer.sampleRate),
                                                 channels: 1, interleaved: true)!
        private var converter: AVAudioConverter?

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, let description = sample.formatDescription,
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: stream),
                  sample.numSamples > 0, sample.numSamples <= Int(format.sampleRate),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
            else { return }
            input.frameLength = input.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength),
                                                              into: input.mutableAudioBufferList) == noErr else { return }

            if converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: outputFormat) }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / format.sampleRate)) + 64
            guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            let status = converter.convert(to: output, error: nil) { _, status in
                status.pointee = supplied ? .noDataNow : .haveData
                defer { supplied = true }
                return supplied ? nil : input
            }
            guard status != .error, let samples = output.int16ChannelData?.pointee else { return }
            buffer.append(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
    }
}
#endif
