import XCTest
@testable import LiveTranslateCore

final class HubCompatibilityTests: XCTestCase {
    private func sib(_ path: String, _ size: Int64 = 10, sha: String? = nil) -> HubSibling {
        HubSibling(path: path, size: size, sha256: sha)
    }

    func testSherpaZipformerEnglishIsListedForEnglishOnly() throws {
        let files = [
            sib("README.md"), sib("tokens.txt"), sib("bpe.model"),
            sib("encoder-epoch-99-avg-1-chunk-16-left-128.onnx"),
            sib("encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", sha: "a"),
            sib("decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx"),
            sib("joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx"),
            sib("test_wavs/0.wav"),
        ]
        let repo = "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26"
        let english = try XCTUnwrap(HubCompatibility.candidate(
            task: .englishSpeech, repo: repo, siblings: files, tags: ["onnx"],
            libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        ))
        XCTAssertEqual(english.runtime, .sherpaStreaming)
        XCTAssertEqual(english.featureDim, 80)
        XCTAssertEqual(english.files.map(\.path), [
            "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "tokens.txt",
        ])
        XCTAssertNil(HubCompatibility.candidate(
            task: .thaiSpeech, repo: repo, siblings: files, tags: ["onnx"],
            libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        ))
    }

    func testOfflineAndGenAIGraphsAreNotListed() {
        // Offline zipformer: right files, not a streaming model.
        XCTAssertNil(HubCompatibility.candidate(
            task: .thaiSpeech, repo: "csukuangfj/sherpa-onnx-zipformer-thai-2024-06-20",
            siblings: [sib("encoder.onnx"), sib("decoder.onnx"), sib("joiner.onnx"), sib("tokens.txt")],
            tags: ["th"], libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        ))
        // onnxruntime-genai layout: joint.onnx and no tokens.txt.
        XCTAssertNil(HubCompatibility.candidate(
            task: .englishSpeech, repo: "onnx-community/nemotron-3.5-asr-streaming-0.6b-onnx-int4",
            siblings: [sib("encoder.onnx"), sib("decoder.onnx"), sib("joint.onnx"), sib("vocab.txt")],
            tags: ["en"], libraryName: "nemo", pipelineTag: nil, downloads: 1, likes: 0
        ))
    }

    func testThaiTyphoonIsNotOfferedAsEnglish() {
        let files = [sib("encoder.onnx"), sib("encoder.onnx.data"), sib("decoder.onnx"), sib("joiner.onnx"), sib("tokens.txt")]
        let repo = "wannaphong/typhoon-asr-streaming-nemotron-0.6b-fp32-onnx"
        let thai = HubCompatibility.candidate(
            task: .thaiSpeech, repo: repo, siblings: files, tags: ["th", "en", "streaming"],
            libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        )
        XCTAssertEqual(thai?.files.map(\.path), ["encoder.onnx", "encoder.onnx.data", "decoder.onnx", "joiner.onnx", "tokens.txt"])
        XCTAssertEqual(thai?.featureDim, 128)
        XCTAssertNil(HubCompatibility.candidate(
            task: .englishSpeech, repo: repo, siblings: files, tags: ["th", "en", "streaming"],
            libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        ))
    }

    func testCoreMLNemotronTakesOnlyTheTrainedChunkFolder() throws {
        let files = [
            sib("README.md"),
            sib("nemotron_coreml_1120ms/encoder/encoder_int8.mlmodelc/weights/weight.bin"),
            sib("nemotron_coreml_1120ms/decoder.mlmodelc/model.mil"),
            sib("nemotron_coreml_1120ms/joint.mlmodelc/model.mil"),
            sib("nemotron_coreml_1120ms/tokenizer.json"),
            sib("nemotron_coreml_2240ms/tokenizer.json"),
        ]
        let candidate = try XCTUnwrap(HubCompatibility.candidate(
            task: .englishSpeech, repo: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
            siblings: files, tags: ["coreml"], libraryName: nil, pipelineTag: nil, downloads: 1, likes: 0
        ))
        XCTAssertEqual(candidate.runtime, .coreMLNemotron)
        XCTAssertEqual(candidate.modelSubfolder, "nemotron_coreml_1120ms")
        XCTAssertTrue(candidate.files.allSatisfy { $0.path.hasPrefix("nemotron_coreml_1120ms/") })
    }

    func testTextModelsAreSplitByTask() {
        let mlx = [sib("config.json"), sib("model.safetensors"), sib("tokenizer.json"), sib("README.md"), sib("modeling.py")]
        func check(_ repo: String, _ task: ModelTask, pipeline: String? = "text-generation") -> HubCandidate? {
            HubCompatibility.candidate(task: task, repo: repo, siblings: mlx, tags: ["mlx"],
                                       libraryName: "mlx", pipelineTag: pipeline, downloads: 1, likes: 0)
        }
        XCTAssertNotNil(check("veha/ChindaMT-4B-MLX-8bit", .translation, pipeline: "translation"))
        XCTAssertNotNil(check("typhoon-ai/typhoon-translate-4b-mlx-4bit", .translation))
        XCTAssertNil(check("typhoon-ai/typhoon-translate-4b-mlx-4bit", .notes))
        XCTAssertNotNil(check("typhoon-ai/typhoon2-qwen2.5-7b-instruct-mlx-4bit", .notes))
        XCTAssertNil(check("typhoon-ai/typhoon2-qwen2.5-7b-mlx-4bit", .notes))
        XCTAssertNil(check("mlx-community/typhoon-ocr1.5-2b-8bit", .notes, pipeline: "image-text-to-text"))
        XCTAssertEqual(check("veha/ChindaMT-4B-MLX-8bit", .translation)?.files.map(\.path),
                       ["config.json", "model.safetensors", "tokenizer.json"])
        // GGUF / transformers checkpoints are not MLX.
        XCTAssertNil(HubCompatibility.candidate(task: .translation, repo: "iapp/ChindaMT-4B", siblings: mlx,
                                                tags: [], libraryName: "transformers", pipelineTag: "translation",
                                                downloads: 1, likes: 0))
    }

    func testSilenceDoesNotLeaveBlankTurns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try ModelCatalog.load(from: root.appendingPathComponent("docs/model-catalog.json"))
        var engine = SessionEngine(catalog: catalog, packID: PackPolicy.macPackID, packInstalled: true,
                                   notes: NotesReducer { _ in NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: []) })
        engine.setListening(true)
        let now = Date(timeIntervalSince1970: 1)
        for index in 0..<10 {
            engine.pushHypothesis("", speakerRaw: nil, at: now.addingTimeInterval(Double(index)), endpoint: index % 3 == 2)
        }
        XCTAssertTrue(engine.turns.isEmpty)
        engine.pushHypothesis("hello there", speakerRaw: nil, at: now.addingTimeInterval(11), endpoint: true)
        engine.pushHypothesis("", speakerRaw: nil, at: now.addingTimeInterval(12), endpoint: true)
        XCTAssertEqual(engine.turns.map(\.sourcePrefix), ["hello there"])
    }

    func testDeferredNotesPassRunsOffTheCallerAndAppliesLater() {
        var calls = 0
        var notes = NotesReducer { _ in
            calls += 1
            return NotesDraft(title: "Budget", titleTurnID: "t1", summary: [], decisions: [], actions: [], openQuestions: [])
        }
        notes.defersModel = true
        let start = Date(timeIntervalSince1970: 100)
        notes.upsert(id: "t1", translation: "The budget was approved.", speaker: "Speaker 1", now: start)
        XCTAssertTrue(notes.isDue(now: start.addingTimeInterval(9)))
        notes.tick(now: start.addingTimeInterval(9))
        XCTAssertEqual(calls, 0)
        let input = notes.takeRequestedPass()
        XCTAssertEqual(input?.turns.map(\.id), ["t1"])
        XCTAssertNil(notes.takeRequestedPass())
        // Stop while the pass runs: it is queued, not lost.
        notes.stop(now: start.addingTimeInterval(10))
        XCTAssertNil(notes.requestedPass)
        notes.finishDeferredPass(notes.model(input!), now: start.addingTimeInterval(11))
        XCTAssertEqual(notes.note.title.text, "Budget")
        XCTAssertNotNil(notes.takeRequestedPass())
        XCTAssertEqual(notes.stopPassCount, 1)
    }
}

final class SessionRecordTests: XCTestCase {
    private func record() -> SessionRecord {
        var note = MeetingNote.empty()
        note.summary = [NoteItem(id: "s", text: "Stores open in January.", turnID: "t1", speaker: "", tentative: false)]
        note.actions = [NoteItem(id: "a", text: "Send the timeline", turnID: "t2", speaker: "Speaker 2", tentative: false)]
        return SessionRecord(
            title: "Supplier call",
            started: Date(timeIntervalSince1970: 0),
            duration: 125,
            direction: .englishToThai,
            turns: [
                SavedTurn(id: "t1", source: "Thanks for joining.", translation: "ขอบคุณที่มาร่วม", speaker: "Sarah", start: 0, end: 2, direction: "en-th"),
                SavedTurn(id: "t2", source: "We can deliver.", translation: "เราส่งได้", speaker: "Speaker 2", start: 60, end: 62, direction: "en-th"),
            ],
            note: note,
            checkedActions: ["a"]
        )
    }

    func testCopyKindsAndOptions() {
        let r = record()
        XCTAssertEqual(r.copyText(.original, options: SessionCopyOptions()), "Sarah: Thanks for joining.\n\nSpeaker 2: We can deliver.")
        XCTAssertEqual(r.copyText(.translation, options: SessionCopyOptions(speakerNames: false)), "ขอบคุณที่มาร่วม\n\nเราส่งได้")
        XCTAssertEqual(r.copyText(.bilingual, options: SessionCopyOptions()), "Sarah\nThanks for joining.\nขอบคุณที่มาร่วม\n\nSpeaker 2\nWe can deliver.\nเราส่งได้")
        let markdown = r.copyText(.bilingual, options: SessionCopyOptions(speakerNames: true, timestamps: false, markdown: true))
        XCTAssertTrue(markdown.hasPrefix("# Supplier call\n\n**Sarah**\nThanks for joining.\n_ขอบคุณที่มาร่วม_"))
        let summary = r.copyText(.summary, options: SessionCopyOptions())
        XCTAssertTrue(summary.contains("Summary\n\nStores open in January."))
        XCTAssertTrue(summary.contains("• Send the timeline (Speaker 2)"))
        XCTAssertTrue(r.copyText(.summary, options: SessionCopyOptions(markdown: true)).contains("- [x] Send the timeline"))
    }

    func testHistoryBasics() throws {
        let r = record()
        XCTAssertEqual(r.speakerCount, 2)
        XCTAssertEqual(SessionRecord.durationText(125), "2 min")
        XCTAssertEqual(SessionRecord.durationText(3900), "1 h 05 min")
        XCTAssertTrue(r.matches("deliver"))
        XCTAssertTrue(r.matches("ส่ง"))
        XCTAssertFalse(r.matches("permit"))
        let now = Date()
        XCTAssertEqual(SessionGroup.of(now, now: now), .today)
        XCTAssertEqual(SessionGroup.of(now.addingTimeInterval(-86_400), now: now), .yesterday)
        XCTAssertEqual(SessionGroup.of(now.addingTimeInterval(-86_400 * 5), now: now), .earlier)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SessionRecord.self, from: r.jsonData()), r)
        XCTAssertTrue(r.markdown().contains("## Action items"))
    }
}
