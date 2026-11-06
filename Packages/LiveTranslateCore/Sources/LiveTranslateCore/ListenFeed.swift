import Foundation

/// The listen loop both app targets call. Samples stay in memory. A missing
/// pack returns before the recognizer runs and does not invent a partial.
enum ListenFeed {
    @discardableResult
    static func push<Decoder: PartialDecoding, Labeler: SpeakerLabeling>(
        samples: [Float],
        engine: inout SessionEngine,
        decoder: inout Decoder,
        labeler: inout Labeler,
        at now: Date
    ) -> TranslationRequest? {
        guard engine.packInstalled, engine.listening else { return nil }
        guard let buffer = AudioBuffer.capture(
            samples: samples,
            sampleRate: AudioBuffer.captureRate,
            filePath: nil
        ) else {
            return nil
        }
        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now)
        return engine.pendingTranslation
    }
}
