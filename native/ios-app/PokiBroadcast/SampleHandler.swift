import AVFoundation
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var writer: AppAudioCapture.Writer?
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AppAudioCapture.sampleRate),
                                       channels: 1, interleaved: true)!

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) { startAudio() }
    override func broadcastResumed() { startAudio() }
    override func broadcastPaused() { stopAudio() }
    override func broadcastFinished() { stopAudio() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp, writer != nil,
              let description = sampleBuffer.formatDescription,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: stream),
              sampleBuffer.numSamples > 0, sampleBuffer.numSamples <= Int(inputFormat.sampleRate),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
        else { return }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(input.frameLength),
                                                          into: input.mutableAudioBufferList) == noErr else { return }

        if converter?.inputFormat != inputFormat { converter = AVAudioConverter(from: inputFormat, to: output) }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * output.sampleRate / inputFormat.sampleRate)) + 64
        guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        let status = converter.convert(to: converted, error: nil) { _, status in
            status.pointee = supplied ? .noDataNow : .haveData
            defer { supplied = true }
            return supplied ? nil : input
        }
        guard status != .error, let samples = converted.int16ChannelData?.pointee, converted.frameLength > 0 else { return }
        do {
            try writer?.append(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        } catch { fail() }
    }

    private func startAudio() {
        guard let directory = AppAudioCapture.directory else { fail(); return }
        do { writer = try AppAudioCapture.Writer(directory: directory) }
        catch { fail() }
    }

    private func stopAudio() {
        try? writer?.stop()
        writer = nil
        converter = nil
    }

    private func fail() {
        stopAudio()
        finishBroadcastWithError(NSError(domain: "PokiAppAudio", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Poki could not open its shared storage for app audio."
        ]))
    }
}
