#if os(macOS)
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// What the Mac is playing (a call, a video), through ScreenCaptureKit. Audio only:
/// the video side is a 2×2 stream at one frame a second that is never read.
/// This app's own sound is excluded. Samples stay in memory like the microphone's.
final class SystemAudioCapture: NSObject, AudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "live-translate.system-audio", qos: .userInitiated)
    /// Guards the callbacks, the stream, and `stopped`: written on main, read on the sample queue.
    private let lock = NSLock()
    private var stream: SCStream?
    private var onSamples: (([Float]) -> Void)?
    private var onError: ((Error) -> Void)?
    private var stopped = false
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioBuffer.captureRate),
        channels: 1,
        interleaved: false
    )

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        lock.lock()
        self.onSamples = onSamples
        self.onError = onError
        stopped = false
        lock.unlock()
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
                lock.lock()
                let stoppedMeanwhile = stopped
                if !stoppedMeanwhile { self.stream = stream }
                lock.unlock()
                // Stop came while the stream was starting: end it instead of capturing forever.
                if stoppedMeanwhile { try? await stream.stopCapture() }
            } catch {
                NSLog("system-audio start failed: %@", String(describing: error))
                lock.lock()
                let report = stopped ? nil : self.onError
                lock.unlock()
                report?(error)
            }
        }
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        onSamples = nil
        onError = nil
        stopped = true
        lock.unlock()
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock()
        let onSamples = self.onSamples
        lock.unlock()
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
        lock.lock()
        let report = stopped ? nil : onError
        lock.unlock()
        report?(error)
    }
}
#endif
