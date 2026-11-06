import FluidAudioDiarizer
import Foundation

/// LS-EEND only. Sortformer is not used. Weights load before Listen turns on.
/// No speaker slot is returned until a finalized segment exists. Slot 0 is the
/// first voice. A failed prepare stays on the push path and still returns nil.
final class LSEENDSpeakerLabeler: SpeakerLabeling {
    private let diarizer = LSEENDDiarizer()
    private var ready = false
    private var lastRaw: Int?
    private(set) var failure: String?
    private(set) var rawTrace: [Int] = []

    var isReady: Bool { ready }

    func prepare() async {
        guard !ready else { return }
        do {
            try await diarizer.initialize(variant: .dihard3)
            ready = diarizer.isAvailable
            if !ready {
                failure = "LS-EEND initialize returned unavailable"
            }
        } catch {
            ready = false
            failure = String(describing: error)
        }
    }

    func speakerRaw(pcm: [Float]) -> Int? {
        guard ready, !pcm.isEmpty else { return lastRaw }
        do {
            try diarizer.addAudio(pcm, sourceSampleRate: 16_000)
            if let update = try diarizer.process(), let raw = update.finalizedSegments.last?.speakerIndex {
                lastRaw = raw
                // Kept for the probe tool only; bounded so a long session can't grow it.
                if rawTrace.count < 10_000 { rawTrace.append(raw) }
            }
        } catch {
            failure = String(describing: error)
            return lastRaw
        }
        return lastRaw
    }

    /// Forgets the previous session's voices so slot 0 is again the first speaker.
    func reset() {
        lastRaw = nil
        rawTrace.removeAll()
        guard ready else { return }
        diarizer.reset()
    }
}
