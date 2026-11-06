import AVFoundation
import Foundation

enum CaptureError: Error {
    case formatUnavailable
}

/// Microphone capture stays in memory. The tap copies 16 kHz mono floats and
/// does not open a file.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var started = false

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioBuffer.captureRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptureError.formatUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
            guard let samples = Self.convert(buffer, converter: converter, target: target) else { return }
            guard let captured = AudioBuffer.capture(samples: samples, sampleRate: AudioBuffer.captureRate, filePath: nil) else {
                return
            }
            onSamples(captured.samples)
        }
        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
