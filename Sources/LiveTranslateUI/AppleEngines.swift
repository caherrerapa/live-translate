#if os(iOS)
import AVFoundation
import Foundation
import FoundationModels
import Speech
import Translation

/// The iPhone runs on Apple's on-device frameworks: Speech for recognition, Translation
/// for each turn, Apple Intelligence for the summary. The system downloads and manages
/// their models, so the app ships none. Each needs iOS 26; older systems show why Listen is off.
enum AppleEngines {
    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static func locale(_ language: SpeechLanguage) -> Locale {
        Locale(identifier: language.prompt)
    }

    /// Waits for async work on a plain GCD thread (the speech queue), giving up after `timeout`.
    static func blocking<T>(timeout: TimeInterval, fallback: T, _ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached(priority: .userInitiated) {
            box.set(await operation())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return fallback }
        return box.get() ?? fallback
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

#if DEBUG
extension AppleEngines {
    /// LT_IOS_PROBE=1: which of the app's languages Apple's recognizer and translator support here.
    static func probe() async -> String {
        guard #available(iOS 26.0, *) else { return "needs iOS 26" }
        var lines: [String] = []
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        lines.append("speech supported \(supported.count): \(supported.sorted().joined(separator: ","))")
        lines.append("speech installed: \(installed.sorted().joined(separator: ","))")
        for language in SpeechLanguage.allCases {
            let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale(language))
            lines.append("speech \(language.code): \(match?.identifier(.bcp47) ?? "none")")
            let dictation = await DictationTranscriber.supportedLocale(equivalentTo: locale(language))
            lines.append("dictation \(language.code): \(dictation?.identifier(.bcp47) ?? "none")")
        }
        for language in SpeechLanguage.allCases where language != .english {
            let status = await AppleTranslator.status(TranslationDirection(source: .english, target: language))
            lines.append("translate en-\(language.code): \(status)")
        }
        lines.append("apple intelligence: \(SystemLanguageModel.default.availability)")
        return lines.joined(separator: "\n")
    }
}
#endif

/// Apple's SpeechTranscriber as a pull-style decoder for the speech worker. Audio goes in
/// as it arrives; results come back on their own task and are read at the next push.
/// A finalized result ends the turn, the same way an endpoint does for the Mac models.
/// Apple only finalizes on its own at long pauses, so a silence gate asks it to finalize.
@available(iOS 26.0, *)
final class AppleSpeechDecoder: LiveSpeechDecoder {
    let engineLabel: String
    private let transcriber: any SpeechModule
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private let captureFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var finished = ""
    private var forming = ""
    private var resultsTask: Task<Void, Never>?

    /// RMS above this is speech, the same gate as the Core ML decoder. About -42 dBFS.
    static let speechRMS: Float = CoreMLNemotronDecoder.speechRMS
    /// Silence after speech that ends a turn, about 0.8 s.
    static let endpointSamples = CoreMLNemotronDecoder.endpointSamples
    /// Distant voices often sit under the RMS gate mid-sentence, so silence alone does not end
    /// a turn: the words must also have stopped changing for 0.6 s.
    static let pausedStableSamples = 9_600
    /// Words unchanged for 1.2 s end a turn once there is a moment of quiet (0.4 s)...
    static let stableSamples = 19_200
    static let stableQuietSamples = 6_400
    /// ...or after 2.5 s at any level, for noisy rooms. A slow recognizer can hold the words
    /// still for over a second while someone is talking, which cut sentences into fragments.
    static let stuckSamples = 40_000
    // Touched only from the speech queue.
    private var samplesSeen = 0
    private var silentSamples = 0
    private var heardSpeech = false
    private var lastForming = ""
    private var formingSince = 0
    private var finalizing = false

    init?(language: SpeechLanguage) {
        let wanted = AppleEngines.locale(language)
        // SpeechTranscriber covers fewer languages (no Thai); DictationTranscriber uses the
        // on-device dictation models, which cover the rest.
        let transcriber: any SpeechModule
        if let locale = Self.supported(wanted, SpeechTranscriber.self) {
            transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            engineLabel = "Apple Speech · on device"
        } else if let locale = Self.supported(wanted, DictationTranscriber.self) {
            transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            engineLabel = "Apple Dictation · on device"
        } else {
            return nil
        }
        // The system downloads the language's model the first time; it is shared with other apps.
        let installed = AppleEngines.blocking(timeout: 600, fallback: false) {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                return true
            } catch {
                return false
            }
        }
        guard installed,
              let capture = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let format = AppleEngines.blocking(timeout: 10, fallback: nil, {
                  await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
              }) else { return nil }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let started = AppleEngines.blocking(timeout: 30, fallback: false) {
            do {
                // Loads the model now, so the first words are not lost to a cold start.
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
                return true
            } catch {
                return false
            }
        }
        guard started else { return nil }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = continuation
        self.analyzerFormat = format
        self.captureFormat = capture
        self.converter = format == capture ? nil : AVAudioConverter(from: capture, to: format)
        listen()
    }

    /// The module's locale for `wanted`. supportedLocale(equivalentTo:) can answer even where the
    /// module has no languages (the Simulator), so the match must also be in the supported list.
    private static func supported<Module: LocaleDependentSpeechModule>(_ wanted: Locale, _ module: Module.Type) -> Locale? {
        AppleEngines.blocking(timeout: 10, fallback: nil) { () async -> Locale? in
            guard let match = await Module.supportedLocale(equivalentTo: wanted) else { return nil }
            let supported = await Module.supportedLocales
            return supported.contains { $0.identifier(.bcp47) == match.identifier(.bcp47) } ? match : nil
        }
    }

    private func listen() {
        let transcriber = self.transcriber
        resultsTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if let speech = transcriber as? SpeechTranscriber {
                    for try await result in speech.results {
                        self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                } else if let dictation = transcriber as? DictationTranscriber {
                    for try await result in dictation.results {
                        self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                }
            } catch {
                return
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        lock.lock()
        if isFinal {
            finished += finished.isEmpty ? text : " " + text
            forming = ""
        } else {
            forming = text
        }
        lock.unlock()
    }

    func decode(_ samples: [Float]) -> StreamStep {
        if let buffer = buffer(samples) {
            input.yield(AnalyzerInput(buffer: buffer))
        }
        samplesSeen += samples.count
        if !samples.isEmpty {
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            if rms > Self.speechRMS {
                heardSpeech = true
                silentSamples = 0
            } else {
                silentSamples += samples.count
            }
        }
        lock.lock()
        defer { lock.unlock() }
        // Finalized text closes the turn; the next words start a new one.
        if !finished.isEmpty {
            let text = finished.trimmingCharacters(in: .whitespacesAndNewlines)
            finished = ""
            finalizing = false
            heardSpeech = false
            return StreamStep(text: text, endpoint: true)
        }
        let text = forming.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != lastForming {
            lastForming = text
            formingSince = samplesSeen
            finalizing = false
        }
        let unchanged = samplesSeen - formingSince
        let paused = heardSpeech && silentSamples >= Self.endpointSamples && unchanged >= Self.pausedStableSamples
        let settled = (unchanged >= Self.stableSamples && silentSamples >= Self.stableQuietSamples)
            || unchanged >= Self.stuckSamples
        if !text.isEmpty, !finalizing, paused || settled {
            // The final result arrives on the results task and closes the turn at a later push.
            finalizing = true
            let analyzer = self.analyzer
            Task.detached(priority: .userInitiated) { try? await analyzer.finalize(through: nil) }
        }
        return StreamStep(text: text, endpoint: false)
    }

    func reset() {
        lock.lock()
        finished = ""
        forming = ""
        lock.unlock()
        silentSamples = 0
        heardSpeech = false
        lastForming = ""
        formingSince = samplesSeen
        finalizing = false
    }

    func close() {
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        AppleEngines.blocking(timeout: 5, fallback: ()) { await analyzer.cancelAndFinishNow() }
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else { return source }
        let ratio = analyzerFormat.sampleRate / captureFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 32
        ) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }
}

/// One Translation session per direction, reused for every turn.
@available(iOS 26.0, *)
@MainActor
final class AppleTranslator {
    let direction: TranslationDirection
    private let session: TranslationSession

    init(direction: TranslationDirection) {
        self.direction = direction
        session = TranslationSession(
            installedSource: Locale.Language(identifier: direction.source.code),
            target: Locale.Language(identifier: direction.target.code)
        )
    }

    /// Empty when the languages are not downloaded yet; the language screen offers the download.
    func translate(_ text: String) async -> String {
        do {
            return try await session.translate(text).targetText
        } catch {
            return ""
        }
    }

    static func status(_ direction: TranslationDirection) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: direction.source.code),
            to: Locale.Language(identifier: direction.target.code)
        )
    }
}

/// The summary from Apple Intelligence's on-device model, with the same prompt and
/// parser as the Mac's notes model. Runs on the notes queue, never the main thread.
@available(iOS 26.0, *)
final class AppleNotesClient: @unchecked Sendable {
    static var isReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func draft(for input: NotesInput) -> NotesDraft {
        let empty = NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
        guard Self.isReady else { return empty }
        let prompt = NotesProductionPass.prompt(for: input)
        let text = AppleEngines.blocking(timeout: 120, fallback: "") {
            do {
                let session = LanguageModelSession()
                return try await session.respond(to: prompt).content
            } catch {
                return ""
            }
        }
        guard !text.isEmpty else { return empty }
        return NotesProductionPass.draft(parsing: text, fallbackTurnID: input.turns.last?.id ?? "")
    }
}
#endif
