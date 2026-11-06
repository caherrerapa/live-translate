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
        let language: SpeechLanguage = value("--language") == "en" ? .english : .thai
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
        engine.direction = language == .thai ? .thaiToEnglish : .englishToThai
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
