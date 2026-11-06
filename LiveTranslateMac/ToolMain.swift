import AVFoundation
import Darwin
import Foundation

@main
enum LiveTranslateMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--decode") {
            SpeechCLI.main()
        } else if args.contains("--notes") {
            NotesCLI.main()
        } else if args.contains("--diarize") {
            DiarizeCLI.main()
        } else if args.contains("--session") {
            SessionCLI.main()
        } else if args.contains("--probe-speech") {
            ProbeCLI.main()
        } else if args.contains("--notion-check") {
            NotionCheckCLI.main()
        } else if args.contains("--hub-search") {
            HubSearchCLI.main()
        } else if args.contains("--snapshot") {
            #if DEBUG
            SnapshotCLI.main()
            #endif
        } else {
            LiveTranslateApp.main()
        }
    }
}

private enum Wav {
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CaptureError.formatUnavailable
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { throw CaptureError.formatUnavailable }
        let frames = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        if file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 {
            return frames
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CaptureError.formatUnavailable
        }
        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames.count) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CaptureError.formatUnavailable
        }
        var consumed = false
        var error: NSError?
        let source = buffer
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard let out = output.floatChannelData else { throw CaptureError.formatUnavailable }
        return Array(UnsafeBufferPointer(start: out[0], count: Int(output.frameLength)))
    }
}

private struct EndpointDecoder: PartialDecoding {
    var endpoint = false
    var text = "room"
    mutating func decode(pcm: [Float]) -> StreamStep {
        _ = pcm
        let step = StreamStep(text: text, endpoint: endpoint)
        endpoint = false
        return step
    }
}

private enum CatalogFiles {
    static func load() throws -> ModelCatalog {
        if let bundled = Bundle.main.url(forResource: "model-catalog", withExtension: "json") {
            return try ModelCatalog.load(from: bundled)
        }
        throw CatalogError.missingFile
    }
}

enum SpeechCLI {
    static func main() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let audio = value("--audio") else {
            fputs("missing --audio\n", stderr)
            exit(2)
        }
        let preset = ChunkPolicy.preset(named: value("--preset"))
        let language = SpeechLanguage(code: value("--language") ?? "th") ?? .thai
        guard let catalog = try? CatalogFiles.load() else {
            fputs("catalog_missing\n", stderr)
            exit(2)
        }
        let storage = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            packInstalled: true,
            notes: NotesReducer { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        )
        let fallbackTarget: SpeechLanguage = language == .english ? .thai : .english
        engine.direction = TranslationDirection(source: language, target: SpeechLanguage(code: value("--target") ?? "") ?? fallbackTarget)
        engine.preset = preset
        let chunk = engine.chunkMilliseconds() ?? 0
        guard let decoder = SherpaStreamingDecoder(
            language: language,
            chunkMS: chunk,
            precision: PackPolicy.speechPrecision(packID: PackPolicy.macPackID),
            installRoot: storage,
            packID: PackPolicy.macPackID
        ) else {
            fputs("graph_missing chunk_ms \(chunk)\n", stderr)
            exit(2)
        }
        print("preset \(preset.rawValue)")
        print("chunk_ms \(chunk)")
        print("graph \(decoder.graphDirectory.path)")
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("sherpa") || path.contains("onnxruntime") || path.contains("LiveTranslate") {
                print("image \(path)")
            }
        }
        guard let samples = try? Wav.read(URL(fileURLWithPath: audio)), !samples.isEmpty else {
            fputs("audio_unreadable\n", stderr)
            exit(2)
        }
        let hop = 640
        let started = Date()
        var offset = 0
        var text = ""
        var firstAudio: Double?
        var cursor = decoder
        while offset < samples.count {
            let end = min(offset + hop, samples.count)
            let step = cursor.decode(pcm: Array(samples[offset..<end]))
            offset = end
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                text = trimmed
                if firstAudio == nil {
                    firstAudio = Double(offset) / 16_000
                }
            }
        }
        cursor.close()
        let audioSeconds = Double(samples.count) / 16_000
        let elapsed = Date().timeIntervalSince(started)
        let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 99
        let first = firstAudio.map { String(format: "%.3f", $0) } ?? "none"
        print("first_audio_s \(first)")
        print(String(format: "audio_s %.3f", audioSeconds))
        print(String(format: "rtf %.3f", rtf))
        print("text \(text)")
        let thai = text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        let english = text.range(of: "[A-Za-z]", options: .regularExpression) != nil
        if language == .thai, !thai { exit(3) }
        if language == .english, !english || thai { exit(3) }
        if preset == .accurate, rtf >= 0.5 { exit(4) }
        if firstAudio == nil { exit(5) }
    }
}

enum NotesCLI {
    static func main() {
        let sentence = "The committee approved the budget on Monday."
        let follow = "Send the signed copy to the archive."
        let client = TyphoonNotesClient()
        client.packID = PackPolicy.macPackID
        var notes = NotesReducer { input in
            NotesProductionPass.produce(input: input) { client.draft(for: $0) }
        }
        let start = Date()
        notes.upsert(id: "t1", translation: sentence, speaker: "Speaker 1", now: start)
        notes.tick(now: start.addingTimeInterval(8))
        notes.upsert(id: "t2", translation: follow, speaker: "Speaker 1", now: start.addingTimeInterval(8))
        notes.tick(now: start.addingTimeInterval(16))
        notes.stop(now: start.addingTimeInterval(16))
        guard let data = try? notes.note.jsonData(), let rendered = String(data: data, encoding: .utf8) else {
            fputs("note_json_failed\n", stderr)
            exit(6)
        }
        print(rendered)
        print("pass_count \(notes.passCount)")
        print("stop_pass_count \(notes.stopPassCount)")
        print("reasons \(notes.reasons.map(\.rawValue).joined(separator: ","))")
        print("upload none")
        let locked = notes.note.summary.contains { !$0.tentative }
            || notes.note.decisions.contains { !$0.tentative }
            || notes.note.actions.contains { !$0.tentative }
            || notes.note.openQuestions.contains { !$0.tentative }
            || (!notes.note.title.text.isEmpty && !notes.note.title.tentative)
        print("repeated_locked \(locked)")
        client.stop()
        if rendered.contains(sentence) || rendered.contains(follow) { exit(6) }
        if notes.stopPassCount != 1 || notes.passCount < 3 { exit(7) }
        if !locked { exit(8) }
        for key in ["\"title\"", "\"summary\"", "\"decisions\"", "\"actions\"", "\"open_questions\""] {
            if !rendered.contains(key) { exit(9) }
        }
    }
}

enum DiarizeCLI {
    static func main() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await run()
            sem.signal()
        }
        sem.wait()
    }

    private static func run() async {
        let root = OnDevicePaths.repoRoot()
        let thaiURL = root?.appendingPathComponent("spikes/fixtures/utt0072.wav")
        let englishURL = root?.appendingPathComponent("spikes/fixtures/en-room.wav")
        guard let thaiURL, let englishURL,
              let thai = try? Wav.read(thaiURL),
              let english = try? Wav.read(englishURL) else {
            fputs("prepare_error fixtures unreadable\n", stderr)
            exit(1)
        }
        let gap = [Float](repeating: 0, count: 16_000)
        let samples = thai + gap + english
        let boundary = thai.count + gap.count
        guard let catalog = try? CatalogFiles.load() else {
            fputs("prepare_error catalog missing\n", stderr)
            exit(1)
        }
        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            packInstalled: true,
            notes: NotesReducer { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        )
        engine.setListening(true)
        var labeler = LSEENDSpeakerLabeler()
        await labeler.prepare()
        if let failure = labeler.failure, !labeler.isReady {
            print("prepare_error \(failure)")
            exit(1)
        }
        if !labeler.isReady {
            print("prepare_error LS-EEND did not become ready")
            exit(1)
        }
        var decoder = EndpointDecoder()
        let hop = 8_000
        var offset = 0
        let started = Date()
        while offset < samples.count {
            let end = min(offset + hop, samples.count)
            let endpoint = offset < thai.count && end >= thai.count
            decoder.endpoint = endpoint
            guard let buffer = AudioBuffer.capture(
                samples: Array(samples[offset..<end]),
                sampleRate: AudioBuffer.captureRate,
                filePath: nil
            ) else { break }
            _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: started.addingTimeInterval(Double(offset) / 16_000))
            offset = end
            _ = boundary
        }
        decoder.endpoint = true
        if let tail = samples.suffix(1).first,
           let buffer = AudioBuffer.capture(samples: [tail], sampleRate: 16_000, filePath: nil) {
            _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: Date())
        }
        let labels = engine.turns.map { "\($0.speakerLabel) locked=\($0.speakerLocked)" }
        print("labeler LSEENDSpeakerLabeler")
        print("raws \(labeler.rawTrace)")
        print("turns \(labels.joined(separator: " | "))")
        let first = engine.turns.first
        let names = Set(engine.turns.map(\.speakerLabel).filter { !$0.isEmpty })
        let locked = first?.speakerLocked == true && first?.speakerLabel == "Speaker 1"
        let second = engine.turns.dropFirst().contains { $0.speakerLabel == "Speaker 2" }
        print("first_locked \(locked)")
        print("second_speaker \(second)")
        if !names.contains("Speaker 1") || !names.contains("Speaker 2") || !locked || !second {
            exit(1)
        }
    }
}

/// Streams a recording through the same path Listen uses: the speech worker on its
/// own queue, the session engine, and the MLX translator. Prints each committed turn
/// with its translation. `--session --audio file.wav --language en|th [--hub dir --dim 80]`
enum SessionCLI {
    static func main() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let audio = value("--audio"), let samples = try? Wav.read(URL(fileURLWithPath: audio)),
              let catalog = try? CatalogFiles.load() else {
            fputs("usage: --session --audio file.wav --language en|th\n", stderr)
            exit(2)
        }
        let language = SpeechLanguage(code: value("--language") ?? "en") ?? .english
        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            packInstalled: true,
            notes: NotesReducer { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        )
        let fallbackTarget: SpeechLanguage = language == .english ? .thai : .english
        engine.direction = TranslationDirection(source: language, target: SpeechLanguage(code: value("--target") ?? "") ?? fallbackTarget)
        let chunk = engine.chunkMilliseconds() ?? 0
        let loadStart = Date()
        let decoder: LiveSpeechDecoder?
        if let hub = value("--hub") {
            let url = URL(fileURLWithPath: hub)
            if value("--runtime") == "coreml" {
                decoder = CoreMLNemotronDecoder(directory: url)
            } else {
                let dim = Int(value("--dim") ?? "80") ?? 80
                decoder = SherpaStreamingDecoder(directory: url, language: language, featureDim: dim, prompted: dim == 128)
            }
        } else {
            decoder = SherpaStreamingDecoder(
                language: language,
                chunkMS: chunk,
                precision: "full",
                installRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                packID: PackPolicy.macPackID
            )
        }
        guard let decoder else {
            fputs("speech_graph_missing\n", stderr)
            exit(3)
        }
        print(String(format: "speech_load_s %.2f engine %@", Date().timeIntervalSince(loadStart), decoder.engineLabel))
        let translator = ChindaTranslator()
        guard translator.start(model: value("--translator").map { URL(fileURLWithPath: $0) }) else {
            fputs("translator_missing\n", stderr)
            exit(4)
        }
        engine.setListening(true)
        let worker = SpeechWorker()
        worker.activate(key: "cli", make: { decoder }, completion: { _ in })
        let updates = DispatchQueue(label: "cli.updates")
        var pending: [SpeechWorker.Update] = []
        worker.start { update in updates.sync { pending.append(update) } }
        if args.contains("--system-audio") {
            // Real ScreenCaptureKit capture: the Mac plays the recording and the session hears its output.
            let capture = SystemAudioCapture()
            var failure: Error?
            var peak: Float = 0
            do {
                try capture.start(onSamples: { samples in
                    for sample in samples { peak = max(peak, abs(sample)) }
                    worker.push(samples)
                }, onError: { failure = $0 })
            } catch {
                failure = error
            }
            Thread.sleep(forTimeInterval: 2)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [audio]
            try? player.run()
            while player.isRunning {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let batch = updates.sync { () -> [SpeechWorker.Update] in defer { pending.removeAll() }; return pending }
                for update in batch {
                    engine.pushHypothesis(update.step.text, speakerRaw: nil, at: Date(), endpoint: update.step.endpoint)
                }
                drain(&engine, translator)
            }
            Thread.sleep(forTimeInterval: 2)
            capture.stop()
            print("system_audio_error \(failure.map { String(describing: $0) } ?? "none") peak \(String(format: "%.3f", peak))")
        }
        // Feed the recording at real-time speed in 20 ms buffers, plus 3 s of silence for the endpoint.
        let tail = [Float](repeating: 0, count: 48_000)
        let all = samples + tail
        let hop = 320
        let started = Date()
        var offset = 0
        var cpuStart = rusage()
        getrusage(RUSAGE_SELF, &cpuStart)
        while offset < all.count && !args.contains("--system-audio") {
            let end = min(offset + hop, all.count)
            worker.push(Array(all[offset..<end]))
            offset = end
            let due = started.addingTimeInterval(Double(offset) / 16_000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let batch = updates.sync { () -> [SpeechWorker.Update] in defer { pending.removeAll() }; return pending }
            for update in batch {
                engine.pushHypothesis(update.step.text, speakerRaw: nil, at: Date(), endpoint: update.step.endpoint)
            }
            drain(&engine, translator)
        }
        // Let the speech queue finish the buffers already handed to it, then apply what it emitted.
        Thread.sleep(forTimeInterval: 1.0)
        let last = updates.sync { () -> [SpeechWorker.Update] in defer { pending.removeAll() }; return pending }
        for update in last {
            engine.pushHypothesis(update.step.text, speakerRaw: nil, at: Date(), endpoint: update.step.endpoint)
        }
        drain(&engine, translator)
        worker.stop()
        engine.stop(at: Date())
        drain(&engine, translator)
        var cpuEnd = rusage()
        getrusage(RUSAGE_SELF, &cpuEnd)
        let cpu = Double(cpuEnd.ru_utime.tv_sec - cpuStart.ru_utime.tv_sec) + Double(cpuEnd.ru_utime.tv_usec - cpuStart.ru_utime.tv_usec) / 1e6
        let audioSeconds = Double(all.count) / 16_000
        for turn in engine.turns {
            print("turn \(turn.id) source: \(turn.sourcePrefix)")
            print("turn \(turn.id) translation: \(turn.translationCommitted)")
        }
        print(String(format: "audio_s %.2f speech_cpu_core_fraction %.2f", audioSeconds, cpu / audioSeconds))
        translator.stop()
        let complete = engine.turns.contains { !$0.translationCommitted.isEmpty }
        exit(complete ? 0 : 5)
    }

    /// Runs pending translations to completion, the way the controller chains them.
    private static func drain(_ engine: inout SessionEngine, _ translator: ChindaTranslator) {
        while let request = engine.pendingTranslation ?? engine.retryTranslation(at: Date()) {
            let semaphore = DispatchSemaphore(value: 0)
            var result = (request.generation, "")
            translator.translate(generation: request.generation, prompt: request.prompt) { generation, text in
                result = (generation, text)
                semaphore.signal()
            }
            // The translator answers on the main queue; spin it while waiting.
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            print("translate \(request.endpoint ? "flush" : "prefix") \"\(request.source)\" -> \"\(result.1)\"")
            _ = engine.deliverTranslation(generation: result.0, text: result.1, at: Date())
        }
    }
}

/// Opens a downloaded sherpa graph and streams a second of silence. Exit 0 means
/// it loads. Run as a child process, because sherpa-onnx exits on a bad graph.
enum ProbeCLI {
    static func main() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let path = value("--probe-speech") else { exit(2) }
        let dim = Int(value("--dim") ?? "80") ?? 80
        let language = SpeechLanguage(code: value("--language") ?? "en") ?? .english
        guard let decoder = SherpaStreamingDecoder(
            directory: URL(fileURLWithPath: path),
            language: language,
            featureDim: dim,
            prompted: dim == 128
        ) else { exit(3) }
        _ = decoder.decode([Float](repeating: 0, count: 16_000))
        decoder.close()
        exit(0)
    }
}

/// Prints what the model screen would list for each task.
enum HubSearchCLI {
    static func main() {
        Task { @MainActor in
            let library = ModelLibrary(storage: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lt-hub-cli"))
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--install"), index + 1 < args.count {
                // Download, hash-check, install and probe one English candidate, as the model screen does.
                let repo = args[index + 1]
                let task = args.firstIndex(of: "--task").flatMap { ModelTask(rawValue: args[$0 + 1]) } ?? .englishSpeech
                library.verifyInstall = { candidate, directory in
                    guard candidate.runtime == .sherpaStreaming else { return MLXSupport.check(directory: directory) }
                    let probe = Process()
                    probe.executableURL = Bundle.main.executableURL
                    probe.arguments = ["--probe-speech", directory.path, "--dim", String(candidate.featureDim), "--language", candidate.task.speechLanguage?.code ?? "en"]
                    try? probe.run()
                    probe.waitUntilExit()
                    return probe.terminationStatus == 0 ? nil : "probe failed"
                }
                await library.search(task)
                guard let candidate = library.results[task]?.first(where: { $0.repo == repo }) else {
                    print("not listed \(repo)")
                    exit(1)
                }
                library.download(candidate)
                while true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let status = library.status(of: candidate)
                    print("status \(status)")
                    if status == .installed {
                        print("installed \(library.modelDirectory(for: candidate).path) selected=\(library.selected(task)?.repo ?? "none")")
                        exit(0)
                    }
                    if case .failed = status { exit(1) }
                }
            }
            let only = args.firstIndex(of: "--task").flatMap { ModelTask(rawValue: args[$0 + 1]) }
            for task in ModelTask.allCases where only == nil || only == task {
                await library.search(task)
                print("== \(task.title)\(library.searchErrors[task].map { " error: \($0)" } ?? "")")
                for candidate in library.results[task] ?? [] {
                    let size = ByteCountFormatter.string(fromByteCount: candidate.totalBytes, countStyle: .file)
                    print("  \(candidate.repo)  [\(candidate.runtime.accelerator)]  \(size)  files=\(candidate.files.count) dim=\(candidate.featureDim)\(candidate.multilingual == true ? " multilingual" : "")")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

#if DEBUG
import AppKit
import SwiftUI

/// Renders a screen offscreen to a PNG: `--snapshot out.png [--models]`. Debug builds only.
enum SnapshotCLI {
    static func main() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { exit(2) }
        let output = URL(fileURLWithPath: args[index + 1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            guard let controller = SessionController.demo() else { exit(3) }
            let models = args.contains("--models")
            if models { controller.stopDemoListening() }
            if args.contains("--missing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.demoPackMissing() }
            }
            let captions = args.contains("--captions")
            let sidebar = args.contains("--sidebar")
            let copyMenu = args.contains("--copymenu")
            let inspector = args.contains("--inspector")
            let size = models ? NSSize(width: 820, height: 640) : captions ? NSSize(width: 780, height: 200)
                : copyMenu ? NSSize(width: 380, height: 440)
                : sidebar ? NSSize(width: 260, height: 900) : inspector ? NSSize(width: 330, height: 900) : NSSize(width: 1440, height: 900)
            let root: AnyView = models
                ? AnyView(ModelScreen(controller: controller, library: controller.library))
                : captions ? AnyView(CaptionsWindow(controller: controller).padding(10))
                : copyMenu ? AnyView(
                    VStack(alignment: .trailing, spacing: 6) {
                        CopyMenuButton(open: .constant(true))
                        CopyMenuPanel(controller: controller, previewHighlight: true) {}
                    }
                    .padding([.top, .horizontal], 20)
                    .frame(width: 380, height: 440, alignment: .topTrailing)
                    .background(Color(hex: 0xF5F5F7))
                )
                : sidebar ? AnyView(SessionSidebar(controller: controller).background(Color(nsColor: .windowBackgroundColor)))
                : inspector ? AnyView(SummaryInspector(controller: controller).background(Color(nsColor: .windowBackgroundColor)))
                : AnyView(MacSessionView(controller: controller))
            let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + (models ? 25 : 3)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(4) }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output)
                    exit(0)
                }
            }
        }
        app.run()
    }
}
#endif

/// Sends a placeholder session through the Notion export with an invalid token:
/// the request is built and sent, and Notion's refusal comes back as a readable error.
enum NotionCheckCLI {
    static func main() {
        Task { @MainActor in
            var note = MeetingNote.empty()
            note.summary = [NoteItem(id: "s", text: "Placeholder summary.", turnID: "t1", speaker: "", tentative: false)]
            note.actions = [NoteItem(id: "a", text: "Placeholder action", turnID: "t1", speaker: "Speaker 1", tentative: false)]
            let turns = (1...130).map { SavedTurn(id: "t\($0)", source: "Placeholder line \($0).", translation: "ข้อความ \($0)", speaker: "Speaker 1", start: Double($0), end: Double($0) + 1, direction: "en-th") }
            let record = SessionRecord(title: "Live Translate check", started: Date(), duration: 60, direction: .englishToThai, turns: turns, note: note)
            let blocks = NotionExport.blocks(for: record)
            print("blocks \(blocks.count) (batched as \(Int((Double(blocks.count) / 100).rounded(.up))) requests)")
            print("page id from link:", NotionExport.pageID(from: "https://www.notion.so/Team-Notes-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d") ?? "nil")
            do {
                _ = try await NotionExport.export(record, settings: .init(token: "ntn_invalid_check_token", parentPageID: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"))
                print("unexpected success")
                exit(1)
            } catch {
                print("notion error:", error.localizedDescription)
                exit(error.localizedDescription.contains("401") ? 0 : 1)
            }
        }
        RunLoop.main.run()
    }
}
