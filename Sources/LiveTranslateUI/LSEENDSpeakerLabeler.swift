#if os(macOS)
import FluidAudioDiarizer
import Foundation

/// LS-EEND only. Sortformer is not used. Weights load before Listen turns on.
/// No speaker slot is returned until a finalized segment exists. Slot 0 is the
/// first voice. A failed prepare stays on the push path and still returns nil.
final class LSEENDSpeakerLabeler: SpeakerLabeling {
    private let diarizer = LSEENDDiarizer()
    private var ready = false
    private var lastRaw: Int?

    func prepare() async {
        guard !ready else { return }
        do {
            try await diarizer.initialize(variant: .dihard3)
            ready = diarizer.isAvailable
        } catch {
            ready = false
        }
    }

    func speakerRaw(pcm: [Float]) -> Int? {
        guard ready, !pcm.isEmpty else { return lastRaw }
        do {
            try diarizer.addAudio(pcm, sourceSampleRate: 16_000)
            if let update = try diarizer.process(), let raw = update.finalizedSegments.last?.speakerIndex {
                lastRaw = raw
            }
        } catch {
            return lastRaw
        }
        return lastRaw
    }
}
#endif
