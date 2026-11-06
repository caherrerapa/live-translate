#if os(macOS)
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// What the Mac is playing (a call, a video), through ScreenCaptureKit. Audio only:
/// the video side is a 2×2 stream at one frame a second that is never read.
/// This app's own sound is excluded. Samples stay in memory like the microphone's.
final class SystemAudioCapture: NSObject, AudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "live-translate.system-audio", qos: .userInitiated)
    private var onSamples: (([Float]) -> Void)?
    private var onError: ((Error) -> Void)?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioBuffer.captureRate),
        channels: 1,
        interleaved: false
    )

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        self.onSamples = onSamples
        self.onError = onError
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw CaptureError.noDisplay }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                NSLog("system-audio start failed: %@", String(describing: error))
                onError(error)
            }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        onSamples = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let onSamples, let target,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return }
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: target)
            converterInput = format
        }
        guard let converter,
              let samples = MicrophoneCapture.convert(pcm, converter: converter, target: target) else { return }
        onSamples(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("system-audio stopped with error: %@", String(describing: error))
        onError?(error)
    }
}
#endif
