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
@available(iOS 26.0, *)
final class AppleSpeechDecoder: LiveSpeechDecoder {
    let engineLabel = "Apple Speech · on device"
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private let captureFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var finished = ""
    private var forming = ""
    private var resultsTask: Task<Void, Never>?

    init?(language: SpeechLanguage) {
        let wanted = AppleEngines.locale(language)
        // supportedLocale(equivalentTo:) can answer even where the transcriber has no languages
        // (the Simulator), so the match must also be in the supported list.
        guard let locale = AppleEngines.blocking(timeout: 10, fallback: nil, { () async -> Locale? in
            guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return nil }
            let supported = await SpeechTranscriber.supportedLocales
            return supported.contains { $0.identifier(.bcp47) == match.identifier(.bcp47) } ? match : nil
        }) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
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

    private func listen() {
        resultsTask = Task.detached(priority: .userInitiated) { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.lock.lock()
                    if result.isFinal {
                        self.finished += self.finished.isEmpty ? text : " " + text
                        self.forming = ""
                    } else {
                        self.forming = text
                    }
                    self.lock.unlock()
                }
            } catch {
                return
            }
        }
    }

    func decode(_ samples: [Float]) -> StreamStep {
        if let buffer = buffer(samples) {
            input.yield(AnalyzerInput(buffer: buffer))
        }
        lock.lock()
        defer { lock.unlock() }
        // Finalized text closes the turn; the next words start a new one.
        if !finished.isEmpty {
            let text = finished.trimmingCharacters(in: .whitespacesAndNewlines)
            finished = ""
            return StreamStep(text: text, endpoint: true)
        }
        return StreamStep(text: forming.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: false)
    }

    func reset() {
        lock.lock()
        finished = ""
        forming = ""
        lock.unlock()
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
