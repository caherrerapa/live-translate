import AVFoundation
import Foundation

enum CaptureError: Error {
    case formatUnavailable
    case noDisplay
}

/// Where the session hears the room.
enum AudioSourceKind: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        }
    }
}

/// 16 kHz mono float buffers from some source, delivered on an audio thread.
protocol AudioCapturing: AnyObject {
    /// `onError` reports a failure that happens after start returns (system audio starts asynchronously).
    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws
    func stop()
}

/// Microphone capture stays in memory. The tap copies 16 kHz mono floats and
/// does not open a file.
final class MicrophoneCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var started = false
    private var onSamples: (([Float]) -> Void)?
    private var onError: ((Error) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        self.onSamples = onSamples
        self.onError = onError
        try installAndStart()
        started = true
        // Plugging in headphones or switching the input device stops the engine and changes
        // the input format. Without a restart the session would go silent with no error.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        guard started else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
        onSamples = nil
        onError = nil
    }

    private func restartAfterConfigurationChange() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installAndStart()
        } catch {
            onError?(error)
        }
    }

    private func installAndStart() throws {
        guard let onSamples else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.formatUnavailable
        }
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
    }

    static func convert(
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
