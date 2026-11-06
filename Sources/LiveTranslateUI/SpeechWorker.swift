import AVFoundation
import FluidAudioDiarizer
import Foundation

/// A streaming recognizer the worker can hold resident and reuse across sessions.
protocol LiveSpeechDecoder: AnyObject {
    /// Shown in the status bar, for example "Neural Engine · Core ML".
    var engineLabel: String { get }
    func decode(_ samples: [Float]) -> StreamStep
    /// Starts a new utterance without reloading weights.
    func reset()
    func close()
}

/// Owns the recognizer and the diarizer on one serial background queue.
/// The microphone tap hands samples straight here, so decoding never runs on
/// the main thread. The main thread hears about a change at most every
/// `emitInterval`, or at once when the text, speaker, or endpoint changes.
final class SpeechWorker: @unchecked Sendable {
    struct Update {
        var step: StreamStep
        var speakerRaw: Int?
    }

    private let queue = DispatchQueue(label: "live-translate.speech", qos: .userInitiated)
    private var resident: [String: LiveSpeechDecoder] = [:]
    private var recency: [String] = []
    private var active: LiveSpeechDecoder?
    private var labeler: LSEENDSpeakerLabeler?
    private var running = false
    private var lastText = ""
    private var lastRaw: Int?
    private var lastEmit: TimeInterval = 0
    private var emit: ((Update) -> Void)?

    /// Two graphs stay loaded: the current direction and the other language.
    static let residentLimit = 2
    /// Unchanged text still reaches the engine this often, so the 0.4 s stability commit can run.
    static let emitInterval: TimeInterval = 0.15

    /// Loads (or reuses) a decoder off the main thread and makes it the active one.
    func activate(
        key: String,
        make: @escaping () -> LiveSpeechDecoder?,
        completion: @escaping @MainActor (LiveSpeechDecoder?) -> Void
    ) {
        queue.async {
            var decoder = self.resident[key]
            if decoder == nil, let made = make() {
                decoder = made
                self.resident[key] = made
            }
            self.recency.removeAll { $0 == key }
            if decoder != nil { self.recency.append(key) }
            while self.recency.count > Self.residentLimit {
                let old = self.recency.removeFirst()
                self.resident.removeValue(forKey: old)?.close()
            }
            decoder?.reset()
            self.active = decoder
            DispatchQueue.main.async { completion(decoder) }
        }
    }

    /// Drops every loaded graph, for example after the user picks another model.
    func evictAll() {
        queue.async {
            self.active = nil
            for decoder in self.resident.values { decoder.close() }
            self.resident.removeAll()
            self.recency.removeAll()
        }
    }

    func setLabeler(_ labeler: LSEENDSpeakerLabeler) {
        queue.async { self.labeler = labeler }
    }

    func start(emit: @escaping (Update) -> Void) {
        queue.async {
            self.active?.reset()
            self.lastText = ""
            self.lastRaw = nil
            self.lastEmit = 0
            self.emit = emit
            self.running = true
        }
    }

    /// Runs after every buffer already handed over, then feeds trailing silence so the
    /// recognizer's look-ahead releases the last words, and reports on the main thread.
    func drain(completion: @escaping @MainActor () -> Void) {
        queue.async {
            if self.running, let decoder = self.active, let emit = self.emit {
                let silence = [Float](repeating: 0, count: 320)
                for _ in 0..<60 {
                    let step = decoder.decode(silence)
                    if step.endpoint || step.text != self.lastText {
                        self.lastText = step.endpoint ? "" : step.text
                        emit(Update(step: step, speakerRaw: self.lastRaw))
                    }
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.emit = nil
            self.active?.reset()
        }
    }

    /// Called from the audio tap thread.
    func push(_ samples: [Float]) {
        queue.async {
            guard self.running, let decoder = self.active, let emit = self.emit else { return }
            let step = decoder.decode(samples)
            let raw = self.labeler?.speakerRaw(pcm: samples)
            let now = ProcessInfo.processInfo.systemUptime
            let changed = step.endpoint || step.text != self.lastText || raw != self.lastRaw
            guard changed || now - self.lastEmit >= Self.emitInterval else { return }
            self.lastText = step.endpoint ? "" : step.text
            self.lastRaw = raw
            self.lastEmit = now
            emit(Update(step: step, speakerRaw: raw))
        }
    }
}

/// FluidAudio's Nemotron streaming English on the Neural Engine. Int8 Core ML,
/// about 65x faster than real time on Apple silicon, with very little CPU.
/// The Core ML graph has no endpoint detector, so a short energy gate closes a turn.
final class CoreMLNemotronDecoder: LiveSpeechDecoder {
    let engineLabel = ModelRuntime.coreMLNemotron.accelerator
    private let manager: StreamingNemotronAsrManager
    private let format: AVAudioFormat
    private var heardSpeech = false
    private var silentSamples = 0

    /// RMS above this is speech. About -42 dBFS.
    static let speechRMS: Float = 0.008
    /// Silence after speech that ends a turn, matching the session's ~0.4–1 s endpoint.
    static let endpointSamples = 12_800

    init?(directory: URL) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        let loaded: Bool = Self.blocking {
            do {
                try await manager.loadModels(from: directory)
                return true
            } catch {
                return false
            }
        }
        guard loaded else { return nil }
        self.manager = manager
        self.format = format
    }

    func decode(_ samples: [Float]) -> StreamStep {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else {
            return StreamStep(text: "", endpoint: false)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: samples.count)
        }
        let manager = self.manager
        let text: String = Self.blocking {
            _ = try? await manager.process(audioBuffer: buffer)
            return await manager.getPartialTranscript()
        }
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        let rms = (energy / Float(samples.count)).squareRoot()
        if rms >= Self.speechRMS {
            heardSpeech = true
            silentSamples = 0
        } else if heardSpeech {
            silentSamples += samples.count
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if heardSpeech, silentSamples >= Self.endpointSamples, !trimmed.isEmpty {
            let final: String = Self.blocking {
                let finished = (try? await manager.finish()) ?? text
                await manager.reset()
                return finished
            }
            heardSpeech = false
            silentSamples = 0
            return StreamStep(text: final.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: true)
        }
        return StreamStep(text: trimmed, endpoint: false)
    }

    func reset() {
        heardSpeech = false
        silentSamples = 0
        let manager = self.manager
        Self.blocking { await manager.reset() }
    }

    func close() {
        let manager = self.manager
        Self.blocking { await manager.cleanup() }
    }

    /// The worker queue is a plain GCD thread, never the main thread, so it may
    /// wait for the actor. The actor runs on the Swift concurrency pool.
    @discardableResult
    private static func blocking<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
