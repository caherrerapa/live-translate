import XCTest
@testable import LiveTranslateCore

final class LiveTranslateCoreTests: XCTestCase {
    func testCatalogPacksAndChunks() throws {
        let catalog = try loadCatalog()
        let mac = try XCTUnwrap(catalog.pack(id: PackPolicy.macPackID))
        let phone = try XCTUnwrap(catalog.pack(id: PackPolicy.phonePackID))

        XCTAssertEqual(ChunkPolicy.preset(named: mac.defaultPreset), .accurate)
        XCTAssertEqual(ChunkPolicy.preset(named: phone.defaultPreset), .accurate)
        XCTAssertEqual(PackPolicy.speechPrecision(packID: mac.id), "full")
        XCTAssertEqual(PackPolicy.speechPrecision(packID: phone.id), "int8")

        XCTAssertEqual(
            mac.models,
            [
                "typhoon-asr-streaming-nemotron-0.6b",
                "typhoon-asr-streaming-nemotron-0.6b-ngram",
                "nemotron-3.5-asr-streaming-0.6b-en",
                "chindamt-4b-8bit",
                "typhoon2-qwen2.5-7b-instruct-4bit",
                "fluidaudio-ls-eend",
            ]
        )
        XCTAssertEqual(
            phone.models,
            [
                "typhoon-asr-streaming-nemotron-0.6b",
                "typhoon-asr-streaming-nemotron-0.6b-ngram",
                "nemotron-3.5-asr-streaming-0.6b-en",
                "chindamt-4b-4bit",
                "typhoon2-3b-instruct-4bit",
                "fluidaudio-ls-eend",
            ]
        )
        XCTAssertFalse(mac.models.contains("typhoon-asr-streaming-115m"))
        XCTAssertFalse(phone.models.contains("typhoon-asr-streaming-115m"))
        XCTAssertFalse(mac.models.contains("chindamt-4b-4bit"))
        XCTAssertFalse(phone.models.contains("chindamt-4b-8bit"))

        XCTAssertTrue(PackPolicy.activeModels(pack: phone, chunkMissed: false).contains(PackPolicy.ngramID))
        XCTAssertFalse(PackPolicy.activeModels(pack: phone, chunkMissed: true).contains(PackPolicy.ngramID))
        XCTAssertTrue(PackPolicy.activeModels(pack: mac, chunkMissed: true).contains(PackPolicy.ngramID))
        XCTAssertEqual(PackPolicy.translatorID(pack: mac, catalog: catalog), "chindamt-4b-8bit")
        XCTAssertEqual(PackPolicy.translatorID(pack: phone, catalog: catalog), "chindamt-4b-4bit")
        XCTAssertEqual(PackPolicy.notesID(pack: mac, catalog: catalog), "typhoon2-qwen2.5-7b-instruct-4bit")
        XCTAssertEqual(PackPolicy.notesID(pack: phone, catalog: catalog), "typhoon2-3b-instruct-4bit")

        let thai = try XCTUnwrap(catalog.model(id: "typhoon-asr-streaming-nemotron-0.6b"))
        let english = try XCTUnwrap(catalog.model(id: "nemotron-3.5-asr-streaming-0.6b-en"))
        XCTAssertEqual(thai.languagePrompt, "th-TH")
        XCTAssertEqual(english.languagePrompt, "en-US")
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .thai, preset: .fast, model: thai), 80)
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .thai, preset: .balanced, model: thai), 480)
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .thai, preset: .accurate, model: thai), 1040)
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .english, preset: .fast, model: english), 80)
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .english, preset: .balanced, model: english), 320)
        XCTAssertEqual(ChunkPolicy.milliseconds(language: .english, preset: .accurate, model: english), 1120)
        XCTAssertEqual(PackPolicy.speechID(pack: mac, catalog: catalog, language: .thai), thai.id)
        XCTAssertEqual(PackPolicy.speechID(pack: mac, catalog: catalog, language: .english), english.id)

        XCTAssertEqual(TranslatorChoice.macModelID(bf16LagSeconds: nil), "chindamt-4b-8bit")
        XCTAssertEqual(TranslatorChoice.macModelID(bf16LagSeconds: 2), "chindamt-4b-8bit")
        XCTAssertEqual(TranslatorChoice.macModelID(bf16LagSeconds: 1.2), "chindamt-4b-bf16")
        XCTAssertTrue(TranslationPrompt.text(source: "hello", direction: .englishToThai).hasPrefix("Translate English to Thai."))
        XCTAssertTrue(TranslationPrompt.text(source: "สวัสดี", direction: .thaiToEnglish).hasPrefix("Translate Thai to English."))
    }

    func testEmptyHashIsNotInstalledAndBadHashDeletesTheFile() async throws {
        let root = try makeRoot()
        let payload = Data("pack-bytes".utf8)
        let counter = OpenCounter(payload: payload, chunkSize: 64, blockSecondRead: false)
        let installer = PackInstaller(root: root) { url, offset in
            counter.make(url: url, offset: offset)
        }
        let bad = PackFileSpec(
            modelID: "speech",
            name: "model.bin",
            sha256: Hash.sha256(Data("other-bytes".utf8)),
            url: fixtureURL
        )
        let rejected = await installer.download(packID: "mac-best", file: bad)
        XCTAssertEqual(rejected, .rejectedHash)
        let url = await installer.fileURL(packID: "mac-best", modelID: "speech", name: "model.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let installed = await installer.isInstalled(packID: "mac-best", files: [bad])
        XCTAssertFalse(installed)

        let empty = PackFileSpec(modelID: "speech", name: "model.bin", sha256: "", url: fixtureURL)
        let unverified = await installer.download(packID: "mac-best", file: empty)
        XCTAssertEqual(unverified, .unverified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let emptyInstalled = await installer.isInstalled(packID: "mac-best", files: [empty])
        XCTAssertFalse(emptyInstalled)

        FileManager.default.createFile(atPath: url.path, contents: payload)
        let stillEmpty = await installer.isInstalled(packID: "mac-best", files: [empty])
        XCTAssertFalse(stillEmpty)
    }

    func testPauseResumeContinuesTheSameDownload() async throws {
        let root = try makeRoot()
        let payload = Data(repeating: 0xAB, count: 250)
        let counter = OpenCounter(payload: payload, chunkSize: 100, blockSecondRead: true)
        let installer = PackInstaller(root: root) { url, offset in
            counter.make(url: url, offset: offset)
        }
        let file = PackFileSpec(
            modelID: "speech",
            name: "model.bin",
            sha256: Hash.sha256(payload),
            url: fixtureURL
        )
        let task = Task { await installer.download(packID: "mac-best", file: file) }
        let source = try await counter.waitForFirst()
        await source.waitUntilBlocked()
        await installer.pause()
        source.unblock()
        let parked = await waitUntilParked(installer)
        if !parked {
            await installer.setListening(true)
            _ = await task.value
            XCTFail("download did not park")
            return
        }
        let url = await installer.fileURL(packID: "mac-best", modelID: "speech", name: "model.bin")
        let partial = try Data(contentsOf: url)
        XCTAssertEqual(partial.count, 200)
        XCTAssertEqual(counter.opens, 1)
        XCTAssertEqual(counter.offsets, [0])

        await installer.resume()
        let result = await task.value
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(counter.opens, 2)
        XCTAssertEqual(counter.offsets, [0, 200])
        let installed = await installer.isInstalled(packID: "mac-best", files: [file])
        XCTAssertTrue(installed)

        try await installer.delete(packID: "mac-best")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let afterDelete = await installer.isInstalled(packID: "mac-best", files: [file])
        XCTAssertFalse(afterDelete)
    }

    func testListeningOpensNoSource() async throws {
        let root = try makeRoot()
        let counter = OpenCounter(payload: Data("x".utf8), chunkSize: 8, blockSecondRead: false)
        let installer = PackInstaller(root: root) { url, offset in
            counter.make(url: url, offset: offset)
        }
        await installer.setListening(true)
        let file = PackFileSpec(
            modelID: "speech",
            name: "model.bin",
            sha256: Hash.sha256(Data("x".utf8)),
            url: fixtureURL
        )
        let result = await installer.download(packID: "mac-best", file: file)
        XCTAssertEqual(result, .blockedByListening)
        XCTAssertEqual(counter.opens, 0)
        let installed = await installer.isInstalled(packID: "mac-best", files: [file])
        XCTAssertFalse(installed)
    }

    func testAudioBufferRejectsAFilePath() throws {
        XCTAssertNil(AudioBuffer.capture(samples: [0.2], sampleRate: 16_000, filePath: "/tmp/mic.wav"))
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: [0.1, -0.2, 0], sampleRate: 16_000, filePath: nil))
        let data = try JSONEncoder().encode(buffer)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sampleRate", "samples"])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("/"))
        XCTAssertFalse(text.contains("file"))
        let mirror = Mirror(reflecting: buffer)
        for child in mirror.children {
            XCTAssertFalse(child.value is URL)
            XCTAssertFalse(child.value is String)
        }
    }

    func testPCMBecomesPrefixTailAndEndpoint() throws {
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "hel", endpoint: false),
            StreamStep(text: "hello wor", endpoint: false),
            StreamStep(text: "hello world", endpoint: false),
            StreamStep(text: "hello word", endpoint: false),
            StreamStep(text: "goodbye", endpoint: false),
            StreamStep(text: "hello world", endpoint: true),
        ])
        var stream = SpeechStream()
        let start = Date(timeIntervalSince1970: 1_000)
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: [0, 0.1, 0], sampleRate: 16_000, filePath: nil))

        let first = stream.push(buffer: buffer, decoder: &decoder, at: start)
        XCTAssertEqual(first.prefix, "")
        XCTAssertEqual(first.tail, "hel")
        XCTAssertFalse(first.committed)

        let second = stream.push(buffer: buffer, decoder: &decoder, at: start.addingTimeInterval(0.1))
        XCTAssertEqual(second.prefix, "hel")
        XCTAssertEqual(second.tail, "lo wor")
        XCTAssertTrue(second.prefix.hasPrefix(first.prefix))

        let third = stream.push(buffer: buffer, decoder: &decoder, at: start.addingTimeInterval(0.2))
        XCTAssertEqual(third.prefix, "hello wor")
        XCTAssertEqual(third.tail, "ld")
        XCTAssertTrue(third.prefix.hasPrefix(second.prefix))

        let replaced = stream.push(buffer: buffer, decoder: &decoder, at: start.addingTimeInterval(0.3))
        XCTAssertEqual(replaced.prefix, "hello wor")
        XCTAssertEqual(replaced.tail, "d")
        XCTAssertNotEqual(replaced.tail, third.tail)

        let contradicted = stream.push(buffer: buffer, decoder: &decoder, at: start.addingTimeInterval(0.35))
        XCTAssertEqual(contradicted.prefix, "hello wor")
        XCTAssertFalse(contradicted.display.hasPrefix("goodbye"))

        let committed = stream.push(buffer: buffer, decoder: &decoder, at: start.addingTimeInterval(0.4))
        XCTAssertTrue(committed.committed)
        XCTAssertEqual(committed.tail, "")
        XCTAssertEqual(committed.prefix, "hello world")
        XCTAssertTrue(committed.prefix.hasPrefix(replaced.prefix))
    }

    func testTranslationPrefixEndpointInFlightAndStale() {
        var scheduler = TranslationScheduler()
        XCTAssertNil(scheduler.consider(
            turnID: "t1",
            sourcePrefix: "one two three",
            direction: .englishToThai,
            endpoint: false
        ))
        let first = scheduler.consider(
            turnID: "t1",
            sourcePrefix: "one two three four",
            direction: .englishToThai,
            endpoint: false
        )
        XCTAssertEqual(first?.source, "one two three four")
        XCTAssertTrue(first?.prompt.contains("EN: one two three four") == true)
        let skipped = scheduler.consider(
            turnID: "t1",
            sourcePrefix: "one two three four five six seven eight",
            direction: .englishToThai,
            endpoint: false
        )
        XCTAssertNil(skipped)
        XCTAssertTrue(scheduler.inFlight)
        XCTAssertFalse(scheduler.deliver(generation: first?.generation ?? 0, translation: "หนึ่ง", endpoint: false))
        XCTAssertEqual(scheduler.committed, "")
        XCTAssertEqual(scheduler.provisional, "")

        let second = scheduler.consider(
            turnID: "t1",
            sourcePrefix: "one two three four five six seven eight",
            direction: .englishToThai,
            endpoint: false
        )
        XCTAssertNotNil(second)
        XCTAssertTrue(scheduler.deliver(generation: second?.generation ?? 0, translation: "สวัสดี", endpoint: false))
        scheduler.noteChunk()
        XCTAssertEqual(scheduler.committed, "สวัสดี")

        let third = scheduler.consider(
            turnID: "t1",
            sourcePrefix: "one two three four five six seven eight nine ten eleven twelve",
            direction: .englishToThai,
            endpoint: false
        )
        XCTAssertTrue(scheduler.deliver(generation: third?.generation ?? 0, translation: "คนละเรื่อง", endpoint: false))
        // A reworded translation of the longer prefix replaces the line instead of being dropped.
        XCTAssertEqual(scheduler.committed + scheduler.provisional, "คนละเรื่อง")

        let thai = String(repeating: "ก", count: 11)
        var thaiScheduler = TranslationScheduler()
        XCTAssertNil(thaiScheduler.consider(turnID: "t1", sourcePrefix: thai, direction: .thaiToEnglish, endpoint: false))
        let grown = thai + "ก"
        XCTAssertNotNil(thaiScheduler.consider(turnID: "t1", sourcePrefix: grown, direction: .thaiToEnglish, endpoint: false))

        var endpointScheduler = TranslationScheduler()
        let endpoint = endpointScheduler.consider(turnID: "t1", sourcePrefix: "hi", direction: .englishToThai, endpoint: true)
        XCTAssertEqual(endpoint?.endpoint, true)
        XCTAssertTrue(endpointScheduler.deliver(generation: endpoint?.generation ?? 0, translation: "สวัสดี", endpoint: true))
        XCTAssertEqual(endpointScheduler.committed, "สวัสดี")
    }

    func testRenameOverlapAndClear() throws {
        var engine = try makeEngine(installed: true)
        let start = Date(timeIntervalSince1970: 5_000)
        engine.setListening(true)
        _ = engine.pushHypothesis("hello there", speakerRaw: 4, at: start, endpoint: false)
        engine.overlap(speakerRaw: 9, seconds: 1)
        XCTAssertEqual(engine.turns.count, 1)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 2")
        XCTAssertFalse(engine.turns[0].speakerLocked)
        _ = engine.pushHypothesis("hello there friend", speakerRaw: 9, at: start.addingTimeInterval(1), endpoint: true)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 2")
        XCTAssertTrue(engine.turns[0].speakerLocked)
        let locked = engine.turns[0].id
        engine.overlap(speakerRaw: 4, seconds: 1)
        XCTAssertEqual(engine.turns[0].id, locked)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 2")

        engine.rename(ordinal: 2, to: "Alex")
        _ = engine.pushHypothesis("the next speaker is back", speakerRaw: 9, at: start.addingTimeInterval(3), endpoint: true)
        XCTAssertEqual(engine.turns.last?.speakerLabel, "Alex")
        engine.clear()
        _ = engine.pushHypothesis("fresh room", speakerRaw: 9, at: start.addingTimeInterval(4), endpoint: true)
        XCTAssertEqual(engine.turns.count, 1)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 1")
        let mirror = Mirror(reflecting: engine.speakers)
        XCTAssertFalse(mirror.children.contains { $0.value is [Float] || $0.value is URL })
    }

    func testNotesHighlightStopAndTranslationGate() throws {
        let counter = CallCounter()
        var notes = NotesReducer { input in
            counter.calls += 1
            counter.last = input
            let turnID = input.turns.last?.id ?? "t1"
            let speaker = input.turns.last?.speaker ?? "Speaker 1"
            return NotesDraft(
                title: "Weekly",
                titleTurnID: turnID,
                summary: [DraftItem(text: "We ship Friday", turnID: turnID, speaker: speaker, contradictsTurnID: nil)],
                decisions: [DraftItem(text: "Ship Friday", turnID: turnID, speaker: speaker, contradictsTurnID: nil)],
                actions: [DraftItem(text: "Send the notes", turnID: turnID, speaker: speaker, contradictsTurnID: nil)],
                openQuestions: [DraftItem(text: "Who owns the pack?", turnID: turnID, speaker: speaker, contradictsTurnID: nil)]
            )
        }
        let start = Date(timeIntervalSince1970: 10_000)
        notes.highlight(turnID: "t1", text: "pin this", speaker: "Speaker 1")
        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(notes.note.highlights.first?.turnID, "t1")

        notes.setTranslationInFlight(true, now: start)
        notes.upsert(id: "t1", translation: longWords(120), speaker: "Speaker 1", now: start)
        notes.tick(now: start.addingTimeInterval(9))
        XCTAssertEqual(notes.passCount, 0)
        notes.stop(now: start.addingTimeInterval(9))
        XCTAssertEqual(notes.stopPassCount, 0)
        notes.setTranslationInFlight(false, now: start.addingTimeInterval(9))
        XCTAssertEqual(notes.stopPassCount, 1)
        XCTAssertEqual(notes.passCount, 1)
        notes.stop(now: start.addingTimeInterval(20))
        XCTAssertEqual(notes.stopPassCount, 1)

        let data = try notes.note.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["title", "summary", "decisions", "actions", "open_questions"] {
            XCTAssertNotNil(object[key], key)
        }
        let decisions = try XCTUnwrap(object["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["turn_id"] as? String, "t1")
        XCTAssertEqual(decisions.first?["tentative"] as? Bool, true)

        var follow = NotesReducer { input in
            counter.calls += 1
            let turnID = input.turns.last?.id ?? ""
            return NotesDraft(
                title: "Weekly",
                titleTurnID: turnID,
                summary: [],
                decisions: [DraftItem(text: "Ship Friday", turnID: turnID, speaker: "Speaker 1", contradictsTurnID: nil)],
                actions: [],
                openQuestions: []
            )
        }
        follow.upsert(id: "t1", translation: "We ship Friday", speaker: "Speaker 1", now: start)
        follow.tick(now: start.addingTimeInterval(7))
        XCTAssertEqual(follow.passCount, 0)
        follow.tick(now: start.addingTimeInterval(8))
        XCTAssertEqual(follow.passCount, 1)
        XCTAssertEqual(follow.reasons, [.timer])
        XCTAssertEqual(follow.note.decisions.first?.tentative, true)
        follow.upsert(id: "t2", translation: "Send the notes today", speaker: "Speaker 1", now: start.addingTimeInterval(8))
        let probed = follow.input(liveTail: "TAIL-NOT-IN-NOTE", audioPath: "/tmp/mic.wav")
        let rendered = String(describing: probed)
        XCTAssertFalse(rendered.contains("TAIL-NOT-IN-NOTE"))
        XCTAssertFalse(rendered.contains("/tmp"))
        XCTAssertFalse(rendered.contains(".wav"))
        XCTAssertTrue(probed.turns.contains { $0.translation == "Send the notes today" })
        XCTAssertTrue(probed.turns.allSatisfy { !$0.translation.contains("TAIL-NOT-IN-NOTE") })
        follow.tick(now: start.addingTimeInterval(16))
        XCTAssertEqual(follow.passCount, 2)
        XCTAssertEqual(follow.note.decisions.first?.tentative, false)
        XCTAssertEqual(follow.note.decisions.first?.text, "Ship Friday")

        let wide = SessionLayout.notesVisible(width: 1280, userHidden: false, shell: .mac, regularWidth: true)
        let tight = SessionLayout.notesVisible(width: 960, userHidden: false, shell: .mac, regularWidth: true)
        XCTAssertTrue(wide)
        XCTAssertFalse(tight)
        XCTAssertEqual(SessionLayout.notesColumnWidth, 320)
        follow.tick(now: start.addingTimeInterval(30))
        XCTAssertEqual(follow.passCount, 2)
    }

    func testListenStatesSaveAndRotation() throws {
        let missing = try makeEngine(installed: false)
        guard case .packMissing(let name) = missing.listenState else {
            return XCTFail("expected the pack name")
        }
        XCTAssertEqual(name, "MacBook Pro M4 32GB, best")
        XCTAssertFalse(missing.listenEnabled)

        var engine = try makeEngine(installed: true)
        XCTAssertEqual(engine.listenState, .idle)
        XCTAssertEqual(ListenPolicy.idleLine, "Listen to translate the room.")
        XCTAssertEqual(engine.chunkMilliseconds(), 1040)
        engine.direction = .englishToThai
        XCTAssertEqual(engine.chunkMilliseconds(), 1120)
        engine.preset = .balanced
        XCTAssertEqual(engine.chunkMilliseconds(), 320)
        engine.preset = .fast
        XCTAssertEqual(engine.chunkMilliseconds(), 80)
        engine.preset = .accurate

        engine.microphoneDenied = true
        XCTAssertEqual(engine.listenState, .microphoneDenied)
        XCTAssertFalse(engine.listenEnabled)
        engine.microphoneDenied = false
        engine.setListening(true)
        XCTAssertEqual(engine.listenState, .listeningSilence)
        XCTAssertTrue(engine.turns.isEmpty)

        let start = Date(timeIntervalSince1970: 20_000)
        _ = engine.pushHypothesis("hello there friend", speakerRaw: 1, at: start, endpoint: true)
        engine.highlightCurrent(now: start)
        XCTAssertEqual(engine.notes.note.highlights.first?.turnID, engine.turns.first?.id)
        XCTAssertEqual(engine.notes.passCount, 0)
        let before = engine.turns
        engine.noteRotation()
        XCTAssertEqual(engine.turns, before)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: false, regularWidth: false), .stacked)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: true, regularWidth: false), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: true, regularWidth: true), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: true, regularWidth: false), .stacked)

        engine.deliverTranslation(generation: engine.pendingTranslation?.generation ?? 0, text: "สวัสดี", at: start.addingTimeInterval(1))
        engine.stop(at: start.addingTimeInterval(1))
        XCTAssertEqual(engine.notes.stopPassCount, 1)
        engine.stop(at: start.addingTimeInterval(2))
        XCTAssertEqual(engine.notes.stopPassCount, 1)
        XCTAssertFalse(engine.listening)

        let saved = engine.saveDocument()
        let data = try saved.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["audio"])
        XCTAssertNil(object["samples"])
        XCTAssertNil(object["file"])
        let savedTurns = try XCTUnwrap(object["turns"] as? [[String: Any]])
        XCTAssertEqual(savedTurns.first?["speaker"] as? String, "Speaker 1")
        XCTAssertEqual(savedTurns.first?["direction"] as? String, "en-th")
        XCTAssertEqual(savedTurns.first?["translation"] as? String, "สวัสดี")
        XCTAssertNotNil(savedTurns.first?["start"])
        XCTAssertNotNil(savedTurns.first?["end"])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("Generate"))
        XCTAssertFalse(text.contains(".wav"))
        XCTAssertEqual(saved.turns.first?.speaker, "Speaker 1")
        XCTAssertEqual(saved.note.highlights.first?.turnID, engine.turns.first?.id)
    }

    func testEnginePushFeedsTheDecoderOnlyWhenThePackIsInstalled() throws {
        let samples: [Float] = [0.1, -0.2, 0.05]
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: samples, sampleRate: AudioBuffer.captureRate, filePath: nil))
        XCTAssertEqual(buffer.samples, samples)
        XCTAssertNil(AudioBuffer.capture(samples: samples, sampleRate: AudioBuffer.captureRate, filePath: "/tmp/room.wav"))

        var missing = try makeEngine(installed: false)
        missing.setListening(true)
        XCTAssertFalse(missing.listening)
        XCTAssertFalse(missing.listenEnabled)
        missing.listening = true
        var ignored = ScriptDecoder(steps: [StreamStep(text: "should not run", endpoint: false)])
        var ignoredLabeler = ScriptLabeler(raws: [1])
        XCTAssertNil(missing.push(buffer: buffer, decoder: &ignored, speakers: &ignoredLabeler, at: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(ignored.index, 0)
        XCTAssertEqual(ignoredLabeler.index, 0)
        XCTAssertTrue(missing.turns.isEmpty)
        XCTAssertNil(missing.pendingTranslation)

        var engine = try makeEngine(installed: true)
        engine.direction = .englishToThai
        engine.setListening(true)
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "one two three four five", endpoint: false),
            StreamStep(text: "one two three four five six", endpoint: false),
            StreamStep(text: "one two three four five six seven", endpoint: true),
        ])
        let now = Date(timeIntervalSince1970: 10_000)
        var labeler = ScriptLabeler(raws: [1])
        let first = try XCTUnwrap(engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now))
        XCTAssertEqual(first.prefix, "")
        XCTAssertEqual(first.tail, "one two three four five")
        XCTAssertNil(engine.pendingTranslation)
        XCTAssertEqual(decoder.index, 1)

        let second = try XCTUnwrap(engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.1)))
        XCTAssertEqual(second.prefix, "one two three four five")
        XCTAssertFalse(second.committed)
        let request = try XCTUnwrap(engine.pendingTranslation)
        XCTAssertEqual(request.generation, 1)
        XCTAssertFalse(request.endpoint)
        XCTAssertTrue(request.prompt.hasPrefix("Translate English to Thai."))
        XCTAssertTrue(request.prompt.contains("EN: one two three four five"))

        let third = try XCTUnwrap(engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.2)))
        XCTAssertTrue(third.committed)
        XCTAssertEqual(third.prefix, "one two three four five six seven")
        XCTAssertEqual(decoder.index, 3)
        XCTAssertFalse(engine.deliverTranslation(generation: 1, text: "หนึ่ง", at: now.addingTimeInterval(0.3)))
        XCTAssertEqual(engine.turns.last?.translationCommitted, "")

        let retry = try XCTUnwrap(engine.retryTranslation(at: now.addingTimeInterval(0.4)))
        XCTAssertNotEqual(retry.generation, 1)
        XCTAssertTrue(retry.endpoint)
        XCTAssertEqual(retry.source, "one two three four five six seven")
        XCTAssertTrue(retry.prompt.contains("EN: one two three four five six seven"))
        XCTAssertTrue(engine.deliverTranslation(generation: retry.generation, text: "หนึ่งสองสาม", at: now.addingTimeInterval(0.5)))
        XCTAssertEqual(engine.turns.last?.translationCommitted, "หนึ่งสองสาม")
        XCTAssertNil(engine.retryTranslation(at: now.addingTimeInterval(0.6)))
    }

    func testInFlightTranslationStaysOnItsTurnWhenTheNextUtteranceStarts() throws {
        var engine = try makeEngine(installed: true)
        engine.direction = .englishToThai
        engine.setListening(true)
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "one two three four", endpoint: true),
            StreamStep(text: "five six seven eight", endpoint: false),
        ])
        var labeler = ScriptLabeler(raws: [7, 3])
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: [0.1, -0.2], sampleRate: AudioBuffer.captureRate, filePath: nil))
        let now = Date(timeIntervalSince1970: 50_000)
        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now)
        let pending = try XCTUnwrap(engine.pendingTranslation)
        XCTAssertEqual(pending.turnID, "t1")
        XCTAssertEqual(engine.turns.count, 1)

        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.2))
        XCTAssertEqual(engine.turns.count, 2)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(engine.turns[1].speakerLabel, "Speaker 2")
        XCTAssertEqual(engine.pendingTranslation?.turnID, "t1")
        XCTAssertEqual(engine.pendingTranslation?.generation, pending.generation)

        XCTAssertTrue(engine.deliverTranslation(generation: pending.generation, text: "หนึ่ง", at: now.addingTimeInterval(0.3)))
        XCTAssertEqual(engine.turns[0].translationCommitted, "หนึ่ง")
        XCTAssertEqual(engine.turns[1].translationCommitted, "")
        XCTAssertEqual(engine.turns[1].translationProvisional, "")
        XCTAssertNil(engine.pendingTranslation)
    }

    func testADueSecondTurnWaitsInsteadOfReplacingTheInFlightRequest() throws {
        var engine = try makeEngine(installed: true)
        engine.direction = .englishToThai
        engine.setListening(true)
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "one two three four", endpoint: true),
            StreamStep(text: "five six seven eight", endpoint: true),
        ])
        var labeler = ScriptLabeler(raws: [1, 1])
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: [0.1], sampleRate: AudioBuffer.captureRate, filePath: nil))
        let now = Date(timeIntervalSince1970: 60_000)
        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now)
        let first = try XCTUnwrap(engine.pendingTranslation)
        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.2))
        XCTAssertEqual(engine.pendingTranslation?.turnID, first.turnID)
        XCTAssertTrue(engine.deliverTranslation(generation: first.generation, text: "หนึ่ง", at: now.addingTimeInterval(0.3)))
        XCTAssertEqual(engine.turns[0].translationCommitted, "หนึ่ง")
        let second = try XCTUnwrap(engine.pendingTranslation)
        XCTAssertEqual(second.turnID, "t2")
        XCTAssertNotEqual(second.turnID, first.turnID)
        XCTAssertTrue(engine.deliverTranslation(generation: second.generation, text: "สอง", at: now.addingTimeInterval(0.4)))
        XCTAssertEqual(engine.turns[1].translationCommitted, "สอง")
        XCTAssertEqual(engine.turns[0].translationCommitted, "หนึ่ง")
    }

    func testRenameUsesTheTappedTurn() throws {
        var engine = try makeEngine(installed: true)
        engine.setListening(true)
        let start = Date(timeIntervalSince1970: 8_000)
        _ = engine.pushHypothesis("first voice speaks", speakerRaw: 7, at: start, endpoint: true)
        _ = engine.pushHypothesis("second voice speaks", speakerRaw: 3, at: start.addingTimeInterval(1), endpoint: true)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(engine.turns[1].speakerLabel, "Speaker 2")
        engine.rename(turnID: engine.turns[0].id, to: "Mina")
        XCTAssertEqual(engine.turns[0].speakerLabel, "Mina")
        XCTAssertEqual(engine.turns[1].speakerLabel, "Speaker 2")
        _ = engine.pushHypothesis("mina again", speakerRaw: 7, at: start.addingTimeInterval(2), endpoint: true)
        XCTAssertEqual(engine.turns.last?.speakerLabel, "Mina")
        XCTAssertEqual(engine.turns[1].speakerLabel, "Speaker 2")
    }

    func testPushAssignsChipsFromTwoRawSpeakerLabels() throws {
        var engine = try makeEngine(installed: true)
        engine.setListening(true)
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "first voice", endpoint: true),
            StreamStep(text: "second voice", endpoint: true),
            StreamStep(text: "first voice again", endpoint: true),
        ])
        var labeler = ScriptLabeler(raws: [7, 3, 7])
        let firstPCM: [Float] = [0.2, -0.1, 0.05]
        let secondPCM: [Float] = [-0.4, 0.3]
        let thirdPCM: [Float] = [0.2, -0.1, 0.05]
        let firstBuffer = try XCTUnwrap(AudioBuffer.capture(samples: firstPCM, sampleRate: AudioBuffer.captureRate, filePath: nil))
        let secondBuffer = try XCTUnwrap(AudioBuffer.capture(samples: secondPCM, sampleRate: AudioBuffer.captureRate, filePath: nil))
        let thirdBuffer = try XCTUnwrap(AudioBuffer.capture(samples: thirdPCM, sampleRate: AudioBuffer.captureRate, filePath: nil))
        let now = Date(timeIntervalSince1970: 70_000)

        _ = engine.push(buffer: firstBuffer, decoder: &decoder, speakers: &labeler, at: now)
        _ = engine.push(buffer: secondBuffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.4))

        XCTAssertEqual(labeler.seen, [firstPCM, secondPCM])
        XCTAssertEqual(engine.turns.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(engine.turns.map(\.speakerOrdinal), [1, 2] as [Int?])
        XCTAssertNotEqual(engine.turns[0].speakerOrdinal, engine.turns[1].speakerOrdinal)

        _ = engine.push(buffer: thirdBuffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.8))
        XCTAssertEqual(labeler.seen, [firstPCM, secondPCM, thirdPCM])
        XCTAssertEqual(engine.turns[2].speakerLabel, "Speaker 1")
        XCTAssertEqual(engine.turns[2].speakerOrdinal, 1 as Int?)
        XCTAssertEqual(engine.turns[2].speakerOrdinal, engine.turns[0].speakerOrdinal)
        XCTAssertEqual(engine.turns[1].speakerLabel, "Speaker 2")
    }

    func testSlotZeroIsSpeakerOneWithNoEarlierFakeRaw() throws {
        var engine = try makeEngine(installed: true)
        engine.setListening(true)
        var decoder = ScriptDecoder(steps: [
            StreamStep(text: "not a speaker yet", endpoint: false),
            StreamStep(text: "still waiting", endpoint: false),
            StreamStep(text: "slot zero speaks", endpoint: true),
            StreamStep(text: "slot one speaks", endpoint: true),
        ])
        var labeler = ScriptLabeler(raws: [nil, nil, 0, 1])
        let buffer = try XCTUnwrap(AudioBuffer.capture(samples: [0.15, -0.05], sampleRate: AudioBuffer.captureRate, filePath: nil))
        let now = Date(timeIntervalSince1970: 80_000)

        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now)
        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.1))
        XCTAssertEqual(labeler.seen.count, 2)
        XCTAssertEqual(engine.turns.count, 1)
        XCTAssertNil(engine.turns[0].speakerOrdinal)
        XCTAssertEqual(engine.turns[0].speakerLabel, "")
        XCTAssertFalse(engine.turns[0].speakerLocked)

        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.2))
        XCTAssertEqual(engine.turns.count, 1)
        XCTAssertEqual(engine.turns[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(engine.turns[0].speakerOrdinal, 1 as Int?)
        XCTAssertTrue(engine.turns[0].speakerLocked)

        _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &labeler, at: now.addingTimeInterval(0.3))
        XCTAssertEqual(engine.turns.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(engine.turns.map(\.speakerOrdinal), [1, 2] as [Int?])
    }

    func testColorIndexSkipsAnUnlabeledTurn() {
        let track = SpeakerTrack()
        XCTAssertNil(track.colorIndex(ordinal: nil, paletteCount: 8))
        XCTAssertNil(track.colorIndex(ordinal: 0, paletteCount: 8))
        XCTAssertEqual(track.colorIndex(ordinal: 1, paletteCount: 8), 0)
        XCTAssertEqual(track.colorIndex(ordinal: 8, paletteCount: 8), 7)
        XCTAssertEqual(track.colorIndex(ordinal: 9, paletteCount: 8), 7)
        for ordinal in [1, 8, 9] {
            let index = track.colorIndex(ordinal: ordinal, paletteCount: 8)
            XCTAssertNotNil(index)
            XCTAssertGreaterThanOrEqual(index ?? -1, 0)
            XCTAssertLessThan(index ?? 8, 8)
        }
    }

    func testSessionScreenUsesColorIndex() throws {
        let source = try sessionScreenSource()
        XCTAssertFalse(source.contains("(ordinal - 1)"))
        XCTAssertTrue(source.contains("colorIndex"))
    }

    func testSessionChromeGroupsTheAlwaysVisibleControls() throws {
        let mac = SessionChrome.describe(shell: .mac)
        XCTAssertEqual(mac.alwaysVisible.map(\.title), ["direction", "Listen/Stop"])
        XCTAssertEqual(mac.prominent, .listenStop)
        XCTAssertNil(mac.bottomProminent)
        let secondaryTitles = Set(mac.secondary.map(\.title))
        for word in ["Highlight", "speakers", "notes", "Fast", "Balanced", "Accurate", "Models", "Type", "Copy", "Save"] {
            XCTAssertTrue(secondaryTitles.contains(word), word)
        }
        XCTAssertEqual(secondaryTitles.count, 10)
        XCTAssertTrue(Set(mac.alwaysVisible).isDisjoint(with: Set(mac.secondary)))
        XCTAssertFalse(mac.alwaysVisible.contains(.highlight))
        XCTAssertFalse(mac.alwaysVisible.contains(.models))
        XCTAssertFalse(mac.alwaysVisible.contains(.type))
        XCTAssertFalse(mac.alwaysVisible.contains(.copy))
        XCTAssertFalse(mac.alwaysVisible.contains(.save))
        XCTAssertFalse(mac.alwaysVisible.contains(.fast))
        XCTAssertFalse(mac.alwaysVisible.contains(.balanced))
        XCTAssertFalse(mac.alwaysVisible.contains(.accurate))

        let pad = SessionChrome.describe(shell: .pad)
        XCTAssertEqual(pad.alwaysVisible, mac.alwaysVisible)
        XCTAssertEqual(pad.secondary, mac.secondary)
        XCTAssertEqual(pad.prominent, .listenStop)

        let phone = SessionChrome.describe(shell: .phone)
        XCTAssertEqual(phone.navigationBar.map(\.title), ["direction", "Models"])
        XCTAssertEqual(phone.bottomProminent, .listenStop)
        XCTAssertEqual(phone.bottomProminent, phone.prominent)
        XCTAssertEqual(phone.bottomBeside.map(\.title), ["Highlight"])
        XCTAssertEqual(phone.pageSwitch.map(\.title), ["Conversation", "Notes"])
        XCTAssertTrue(phone.alwaysVisible.isEmpty)
        XCTAssertTrue(phone.navigationBar.contains(.models))
        XCTAssertFalse(phone.navigationBar.contains(.listenStop))
        XCTAssertNotEqual(phone.bottomBeside.first, phone.bottomProminent)

        XCTAssertEqual(SessionLayout.arrangement(shell: .mac, landscape: false, regularWidth: true), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .mac, landscape: true, regularWidth: false), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: false, regularWidth: false), .stacked)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: false, regularWidth: true), .stacked)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: true, regularWidth: false), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .phone, landscape: true, regularWidth: true), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: false, regularWidth: true), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: true, regularWidth: true), .sideBySide)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: true, regularWidth: false), .stacked)
        XCTAssertEqual(SessionLayout.arrangement(shell: .pad, landscape: false, regularWidth: false), .stacked)

        XCTAssertEqual(ListenPolicy.idleLine, "Listen to translate the room.")
        XCTAssertEqual(NotesReducer.emptyLine, "Notes appear as the conversation commits.")
        let missing = ListenPolicy.state(
            packInstalled: false,
            packName: "MacBook Pro M4 32GB, best",
            microphoneDenied: false,
            listening: false,
            hasLivePartial: false
        )
        guard case .packMissing(let packName) = missing else {
            return XCTFail("expected a missing pack")
        }
        XCTAssertEqual(packName, "MacBook Pro M4 32GB, best")
        XCTAssertFalse(ListenPolicy.listenEnabled(missing))

        let source = try sessionScreenSource()
        XCTAssertTrue(source.contains("SessionChrome.describe(shell: shell)"))
        let phoneBody = try sourceSlice(source, from: "private var phoneBody", to: "private var macBar")
        // iPhone: the iOS design's own screens (start, live, session) replace the shared bar layout.
        XCTAssertTrue(phoneBody.contains("PhoneAppView(controller: controller)"))
        // Mac: direction and Listen lead the bar; every secondary control is one click away, not in a popover.
        let macBar = try sourceSlice(source, from: "private var macBar", to: "private func barButton")
        XCTAssertTrue(macBar.contains("directionPicker"))
        XCTAssertTrue(macBar.contains("listenButton"))
        XCTAssertTrue(macBar.contains("ForEach(chrome.secondary"))
        XCTAssertTrue(source.contains("controller.showModels = true"))
        XCTAssertTrue(source.contains("controller.openSettings"))
        XCTAssertTrue(source.contains("controller.highlight"))
        XCTAssertTrue(source.contains("controller.copyTranscript"))
        XCTAssertTrue(source.contains("controller.copyAll(.source)"))
        XCTAssertTrue(source.contains("controller.copy(turn: turn, part: part)"))
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
        XCTAssertTrue(source.contains("controller.exportPresented = true"))
        XCTAssertTrue(source.contains("controller.toggleSpeakers"))
        XCTAssertTrue(source.contains("controller.toggleNotes"))
        XCTAssertTrue(source.contains(".disabled(controller.engine.listening)"))
        XCTAssertTrue(source.contains("controller.engine.listenEnabled && controller.engine.packInstalled"))
        XCTAssertTrue(source.contains("ListenPolicy.idleLine"))
        XCTAssertTrue(source.contains("NotesReducer.emptyLine"))
        XCTAssertTrue(source.contains("turn.sourcePrefix"))
        XCTAssertTrue(source.contains("turn.sourceTail"))
        for title in ["Summary", "Decisions", "Actions", "Open questions", "Highlights"] {
            XCTAssertTrue(source.contains("block(\"\(title)\""), title)
        }
    }

    func testMatchingHashInstallsThePackAndEnablesListen() async throws {
        let catalog = try loadCatalog()
        let thai = try XCTUnwrap(catalog.model(id: "typhoon-asr-streaming-nemotron-0.6b"))
        let english = try XCTUnwrap(catalog.model(id: "nemotron-3.5-asr-streaming-0.6b-en"))
        XCTAssertEqual(thai.files.map(\.name), ["encoder.onnx", "encoder.data", "decoder.onnx", "joiner.onnx", "tokens.txt"])
        XCTAssertEqual(english.files.map(\.name), ["encoder.onnx", "encoder.data", "decoder.onnx", "joiner.onnx", "tokens.txt"])
        XCTAssertTrue(thai.files.allSatisfy(\.hasHash))
        XCTAssertTrue(english.files.allSatisfy(\.hasHash))
        XCTAssertEqual(thai.files.map(\.sha256), [
            "8a8a483b7223082165fffa03bd6ae9b9b49cf1766aa777b8ab670bd4efe43046",
            "099e33cd2460d4a26f19f0c8d0e934c284d6ed9b4476323d4f9c1ebcc724470d",
            "0307d9dc95a29d14f69d5008413569c9576bf88458f08b6059e08fb5559444f4",
            "80f7c984e6518ea14f9638d6dafba1c291a70b474e2e8961c007ccc9408c4b0c",
            "70300c69129e0e67469d25fd8c39a486f342439be3a56eb62f656c32a26e21c4",
        ])
        XCTAssertEqual(english.files.map(\.sha256), [
            "2907fbabae92f6d30c365486391c5df957ccca79b98f78f16e310140f3e621a4",
            "7584f85df76bc9ae6fbdfa53aa8d97b07a842525d1c501d536d77fd9e4f57ac7",
            "0b66e1786b8832196a48d65786aa19650c881218b0f495046ca8579853b200ab",
            "a2a49921684d7d06d488df43b1e174df1a5fb1891805d5582ab4cd88e62af938",
            "729cc103155bafa785f9cd45746cd41cabe97eab7182fc04d594129587958f8a",
        ])
        XCTAssertTrue(try XCTUnwrap(catalog.model(id: "typhoon-asr-streaming-nemotron-0.6b-ngram")).files.isEmpty)
        XCTAssertTrue(try XCTUnwrap(catalog.model(id: "chindamt-4b-8bit")).files.isEmpty)
        XCTAssertEqual(try XCTUnwrap(catalog.pack(id: PackPolicy.macPackID)).models.contains("chindamt-4b-8bit"), true)

        let root = try makeRoot()
        let installer = PackInstaller(root: root) { url, offset in
            RangeByteSource(url: url, offset: offset)
        }
        let payload = Data("speech-graph".utf8)
        let sourceDir = try makeRoot()
        let source = sourceDir.appendingPathComponent("encoder.onnx")
        FileManager.default.createFile(atPath: source.path, contents: payload)
        let spec = PackFileSpec(
            modelID: "typhoon-asr-streaming-nemotron-0.6b",
            name: "encoder.onnx",
            sha256: Hash.sha256(payload),
            url: nil
        )
        await installer.adoptIfMissing(packID: PackPolicy.macPackID, file: spec, source: source)
        let installed = await installer.isInstalled(packID: PackPolicy.macPackID, files: [spec])
        XCTAssertTrue(installed)
        let linked = await installer.fileURL(packID: PackPolicy.macPackID, modelID: spec.modelID, name: spec.name)
        XCTAssertEqual(try Data(contentsOf: linked), payload)

        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            packInstalled: installed,
            notes: NotesReducer { _ in NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: []) }
        )
        XCTAssertTrue(engine.listenEnabled)
        XCTAssertEqual(engine.listenState, .idle)
        engine.setListening(true)
        XCTAssertTrue(engine.listening)

        let wrong = PackFileSpec(modelID: spec.modelID, name: spec.name, sha256: Hash.sha256(Data("other".utf8)), url: nil)
        let mismatched = await installer.isInstalled(packID: PackPolicy.macPackID, files: [wrong])
        XCTAssertFalse(mismatched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))

        let empty = PackFileSpec(modelID: spec.modelID, name: "tokens.txt", sha256: "", url: nil)
        FileManager.default.createFile(atPath: source.path, contents: payload)
        await installer.adoptIfMissing(packID: PackPolicy.macPackID, file: spec, source: source)
        let skippedEmpty = await installer.isInstalled(packID: PackPolicy.macPackID, files: [spec, empty])
        XCTAssertFalse(skippedEmpty)

        await installer.suppressAdopt(packID: PackPolicy.macPackID)
        try await installer.delete(packID: PackPolicy.macPackID)
        await installer.adoptIfMissing(packID: PackPolicy.macPackID, file: spec, source: source)
        let afterDelete = await installer.isInstalled(packID: PackPolicy.macPackID, files: [spec])
        XCTAssertFalse(afterDelete)
    }

    func testChunkPresetSelectsTrainedGraph() throws {
        let catalog = try loadCatalog()
        let thai = try XCTUnwrap(catalog.model(id: "typhoon-asr-streaming-nemotron-0.6b"))
        let english = try XCTUnwrap(catalog.model(id: "nemotron-3.5-asr-streaming-0.6b-en"))
        let thaiFast = try XCTUnwrap(ChunkPolicy.milliseconds(language: .thai, preset: .fast, model: thai))
        let thaiBalanced = try XCTUnwrap(ChunkPolicy.milliseconds(language: .thai, preset: .balanced, model: thai))
        let thaiAccurate = try XCTUnwrap(ChunkPolicy.milliseconds(language: .thai, preset: .accurate, model: thai))
        let englishFast = try XCTUnwrap(ChunkPolicy.milliseconds(language: .english, preset: .fast, model: english))
        let englishBalanced = try XCTUnwrap(ChunkPolicy.milliseconds(language: .english, preset: .balanced, model: english))
        let englishAccurate = try XCTUnwrap(ChunkPolicy.milliseconds(language: .english, preset: .accurate, model: english))
        XCTAssertEqual(SpeechGraphs.directoryName(language: .thai, chunkMS: thaiFast, precision: "full"), "typhoon-0.6b-80")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .thai, chunkMS: thaiBalanced, precision: "full"), "typhoon-0.6b-480")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .thai, chunkMS: thaiAccurate, precision: "full"), "typhoon-0.6b-1040")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .english, chunkMS: englishFast, precision: "full"), "nemotron-en-80")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .english, chunkMS: englishBalanced, precision: "full"), "nemotron-en-320")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .english, chunkMS: englishAccurate, precision: "full"), "nemotron-en-1120")
        XCTAssertEqual(SpeechGraphs.directoryName(language: .thai, chunkMS: thaiAccurate, precision: "int8"), "typhoon-0.6b-1040-int8")
        XCTAssertEqual(PackPolicy.speechPrecision(packID: PackPolicy.phonePackID), "int8")
    }

    func testProductionNotesPassRejectsCopiedTranslation() {
        let sentence = "Please send the notes today."
        let input = NotesInput(
            note: .empty(),
            turns: [NotesTurn(id: "t1", translation: sentence, speaker: "Speaker 1", folded: false)]
        )
        let copied = NotesDraft(
            title: sentence,
            titleTurnID: "t1",
            summary: [DraftItem(text: sentence, turnID: "t1", speaker: "Speaker 1", contradictsTurnID: nil)],
            decisions: [DraftItem(text: sentence, turnID: "t1", speaker: "Speaker 1", contradictsTurnID: nil)],
            actions: [DraftItem(text: "Send the notes", turnID: "t1", speaker: "Speaker 1", contradictsTurnID: nil)],
            openQuestions: []
        )
        let stored = NotesProductionPass.produce(input: input) { _ in copied }
        XCTAssertNotEqual(stored.title, sentence)
        XCTAssertTrue(stored.title.isEmpty)
        XCTAssertTrue(stored.summary.isEmpty)
        XCTAssertTrue(stored.decisions.isEmpty)
        XCTAssertEqual(stored.actions.map(\.text), ["Send the notes"])
        XCTAssertFalse(stored.actions.contains { $0.text == sentence })

        let bareSentence = "Please send the notes today"
        let bare = NotesDraft(
            title: bareSentence,
            titleTurnID: "t1",
            summary: [DraftItem(text: bareSentence, turnID: "t1", speaker: "Speaker 1", contradictsTurnID: nil)],
            decisions: [],
            actions: [],
            openQuestions: []
        )
        let stripped = NotesProductionPass.produce(input: input) { _ in bare }
        XCTAssertTrue(stripped.title.isEmpty)
        XCTAssertTrue(stripped.summary.isEmpty)
    }

    func testIPhoneListenPushesCapturedSamples() throws {
        let catalog = try loadCatalog()
        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.phonePackID,
            packInstalled: true,
            notes: NotesReducer { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        )
        engine.setListening(true)
        var decoder = RecordingDecoder(text: "hello room")
        var labeler = ScriptLabeler(raws: [0])
        let samples: [Float] = [0.02, -0.01, 0.03, 0.0]
        _ = ListenFeed.push(samples: samples, engine: &engine, decoder: &decoder, labeler: &labeler, at: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(decoder.seen, [samples])
        XCTAssertEqual(labeler.seen, [samples])
        XCTAssertTrue(engine.turns.first?.sourceDisplay.contains("hello room") == true)

        var missing = engine
        missing.packInstalled = false
        missing.clear()
        var silent = RecordingDecoder(text: "invented partial")
        var quiet = ScriptLabeler(raws: [1])
        _ = ListenFeed.push(samples: samples, engine: &missing, decoder: &silent, labeler: &quiet, at: Date(timeIntervalSince1970: 4_000))
        XCTAssertTrue(silent.seen.isEmpty)
        XCTAssertTrue(missing.turns.isEmpty)

        var screen = URL(fileURLWithPath: #filePath)
        var source = ""
        for _ in 0..<8 {
            screen.deleteLastPathComponent()
            let candidate = screen.appendingPathComponent("Sources/LiveTranslateUI/SessionController.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                source = try String(contentsOf: candidate, encoding: .utf8)
                break
            }
        }
        // Samples go from the tap to the speech worker queue; the main thread never decodes.
        XCTAssertTrue(source.contains("worker.push(samples)"))
        XCTAssertFalse(source.contains("decoder.decode("))
        XCTAssertFalse(source.contains("_ = buffer.samples"))
    }

    private func sessionScreenSource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Sources/LiveTranslateUI/SessionScreen.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        XCTFail("SessionScreen.swift")
        return ""
    }

    private func sourceSlice(_ source: String, from startMark: String, to endMark: String) throws -> String {
        guard let start = source.range(of: startMark),
              let end = source.range(of: endMark, range: start.upperBound..<source.endIndex) else {
            XCTFail("missing \(startMark) .. \(endMark)")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private struct ScriptLabeler: SpeakerLabeling {
    var raws: [Int?]
    var index = 0
    var seen: [[Float]] = []

    mutating func speakerRaw(pcm: [Float]) -> Int? {
        seen.append(pcm)
        let raw: Int? = raws.isEmpty ? nil : raws[min(index, raws.count - 1)]
        index += 1
        return raw
    }
}

private struct RecordingDecoder: PartialDecoding {
    var text: String
    var seen: [[Float]] = []

    mutating func decode(pcm: [Float]) -> StreamStep {
        seen.append(pcm)
        return StreamStep(text: text, endpoint: false)
    }
}

private struct ScriptDecoder: PartialDecoding {
    var steps: [StreamStep]
    var index = 0

    mutating func decode(pcm: [Float]) -> StreamStep {
        let step = steps[min(index, steps.count - 1)]
        index += 1
        return step
    }
}

private final class CallCounter {
    var calls = 0
    var last: NotesInput?
}

private func loadCatalog() throws -> ModelCatalog {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
        url.deleteLastPathComponent()
        let candidate = url.appendingPathComponent("docs/model-catalog.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try ModelCatalog.load(from: candidate)
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

private func makeEngine(installed: Bool) throws -> SessionEngine {
    let catalog = try loadCatalog()
    let notes = NotesReducer { input in
        let turnID = input.turns.last?.id ?? ""
        let speaker = input.turns.last?.speaker ?? ""
        let text = input.turns.last?.translation ?? ""
        return NotesDraft(
            title: text.isEmpty ? "" : "Room",
            titleTurnID: turnID,
            summary: text.isEmpty ? [] : [DraftItem(text: text, turnID: turnID, speaker: speaker, contradictsTurnID: nil)],
            decisions: [],
            actions: [],
            openQuestions: []
        )
    }
    return SessionEngine(catalog: catalog, packID: PackPolicy.macPackID, packInstalled: installed, notes: notes)
}

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func longWords(_ count: Int) -> String {
    (1...count).map { "word\($0)" }.joined(separator: " ")
}

private let fixtureURL = URL(string: "https://huggingface.co/example/resolve/main/model.bin")!

private final class OpenCounter: @unchecked Sendable {
    let lock = NSLock()
    let payload: Data
    let chunkSize: Int
    let blockSecondRead: Bool
    private(set) var opens = 0
    private(set) var offsets: [Int64] = []
    private var first: ScriptedByteSource?
    private var waiter: CheckedContinuation<ScriptedByteSource, Never>?

    init(payload: Data, chunkSize: Int, blockSecondRead: Bool) {
        self.payload = payload
        self.chunkSize = chunkSize
        self.blockSecondRead = blockSecondRead
    }

    func make(url: URL, offset: Int64) -> ScriptedByteSource {
        lock.lock()
        opens += 1
        offsets.append(offset)
        let block = blockSecondRead && opens == 1 ? 1 : nil
        let source = ScriptedByteSource(
            payload: payload,
            offset: Int(offset),
            chunkSize: chunkSize,
            blockAtRead: block
        )
        if first == nil {
            first = source
        }
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: source)
        return source
    }

    func waitForFirst() async throws -> ScriptedByteSource {
        if let first { return first }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let first {
                lock.unlock()
                continuation.resume(returning: first)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

private final class ScriptedByteSource: ByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private var offset: Int
    private let chunkSize: Int
    private let blockAtRead: Int?
    private var reads = 0
    private var blocker: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var released = false

    init(payload: Data, offset: Int, chunkSize: Int, blockAtRead: Int?) {
        self.payload = payload
        self.offset = offset
        self.chunkSize = chunkSize
        self.blockAtRead = blockAtRead
    }

    func read(maxLength: Int) async throws -> Data? {
        let readIndex: Int = lock.withLock {
            let index = reads
            reads += 1
            return index
        }
        if readIndex == blockAtRead {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                blocker = continuation
                let entered = self.entered
                self.entered = nil
                lock.unlock()
                entered?.resume()
            }
        }
        return lock.withLock {
            guard offset < payload.count else { return nil }
            let count = min(chunkSize, maxLength, payload.count - offset)
            let slice = payload.subdata(in: offset..<(offset + count))
            offset += count
            return slice
        }
    }

    func close() {}

    func waitUntilBlocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if blocker != nil || released {
                lock.unlock()
                continuation.resume()
                return
            }
            entered = continuation
            lock.unlock()
        }
    }

    func unblock() {
        lock.lock()
        released = true
        let blocker = self.blocker
        self.blocker = nil
        let entered = self.entered
        self.entered = nil
        lock.unlock()
        blocker?.resume()
        entered?.resume()
    }
}

private func waitUntilParked(_ installer: PackInstaller) async -> Bool {
    for _ in 0..<100 {
        if await installer.isParked {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
