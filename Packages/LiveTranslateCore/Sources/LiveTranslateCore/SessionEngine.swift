import Foundation

struct SessionTurn: Identifiable, Equatable {
    var id: String
    var speakerOrdinal: Int?
    var speakerLabel: String
    var speakerLocked: Bool
    var sourcePrefix: String
    var sourceTail: String
    var translationCommitted: String
    var translationProvisional: String
    var start: TimeInterval
    var end: TimeInterval?
    var committed: Bool
    var direction: TranslationDirection

    var sourceDisplay: String { sourcePrefix + (committed ? "" : sourceTail) }
    var hasLivePartial: Bool { !committed && !sourceTail.isEmpty }
}

struct SessionEngine {
    var catalog: ModelCatalog
    var packID: String
    var packInstalled: Bool
    var microphoneDenied: Bool
    var direction: TranslationDirection
    var preset: LatencyPreset
    var listening = false
    var notesHidden = false
    var speakers = SpeakerTrack()
    var notes: NotesReducer
    private(set) var turns: [SessionTurn] = []
    private var builders: [String: TurnBuilder] = [:]
    private var schedulers: [String: TranslationScheduler] = [:]
    private var turnsAwaitingTranslation: [String] = []
    private var retryTurnID: String?
    private var nextTurnNumber = 1
    private var sessionStarted: Date?
    var pendingTranslation: TranslationRequest?
    var focusedTurnID: String?

    init(catalog: ModelCatalog, packID: String, packInstalled: Bool, notes: NotesReducer) {
        self.catalog = catalog
        self.packID = packID
        self.packInstalled = packInstalled
        self.microphoneDenied = false
        self.direction = .thaiToEnglish
        self.preset = ChunkPolicy.preset(named: catalog.pack(id: packID)?.defaultPreset)
        self.notes = notes
    }

    /// When the first words of this session arrived. Turn times are offsets from it.
    var startedAt: Date? { sessionStarted }

    var packName: String {
        catalog.pack(id: packID)?.title ?? packID
    }

    var listenState: ListenState {
        ListenPolicy.state(
            packInstalled: packInstalled,
            packName: packName,
            microphoneDenied: microphoneDenied,
            listening: listening,
            hasLivePartial: turns.contains(where: \.hasLivePartial)
        )
    }

    var listenEnabled: Bool {
        ListenPolicy.listenEnabled(listenState)
    }

    func chunkMilliseconds() -> Int? {
        guard let pack = catalog.pack(id: packID),
              let speechID = PackPolicy.speechID(pack: pack, catalog: catalog, language: direction.source),
              let model = catalog.model(id: speechID) else { return nil }
        return ChunkPolicy.milliseconds(language: direction.source, preset: preset, model: model)
    }

    mutating func setListening(_ on: Bool) {
        guard on == false || listenEnabled || listening else { return }
        if on && !packInstalled { return }
        listening = on
    }

    /// Rotation and size-class changes keep the turns.
    mutating func noteRotation() {}

    mutating func clear() {
        turns.removeAll()
        builders.removeAll()
        schedulers.removeAll()
        turnsAwaitingTranslation.removeAll()
        retryTurnID = nil
        speakers.clear()
        let defers = notes.defersModel
        notes = NotesReducer(model: notes.model)
        notes.defersModel = defers
        pendingTranslation = nil
        focusedTurnID = nil
        nextTurnNumber = 1
        listening = false
        sessionStarted = nil
    }

    @discardableResult
    mutating func push<Decoder: PartialDecoding, Labeler: SpeakerLabeling>(
        buffer: AudioBuffer,
        decoder: inout Decoder,
        speakers labeler: inout Labeler,
        at now: Date
    ) -> TurnSnapshot? {
        guard packInstalled, listening else { return nil }
        let step = decoder.decode(pcm: buffer.samples)
        let raw = labeler.speakerRaw(pcm: buffer.samples)
        return pushHypothesis(step.text, speakerRaw: raw, at: now, endpoint: step.endpoint)
    }

    @discardableResult
    mutating func pushHypothesis(
        _ hypothesis: String,
        speakerRaw: Int?,
        at now: Date,
        endpoint: Bool
    ) -> TurnSnapshot {
        if sessionStarted == nil {
            sessionStarted = now
        }
        // Silence produces empty hypotheses and empty endpoints. They must not open
        // or commit blank turns; an open turn with no words is dropped instead.
        let blank = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let openTurnIsBlank = turns.last.map { !$0.committed && $0.sourcePrefix.isEmpty && $0.sourceTail.isEmpty } ?? false
        if blank && (turns.isEmpty || turns[turns.count - 1].committed || openTurnIsBlank) {
            if endpoint && openTurnIsBlank, let id = turns.last?.id {
                turns.removeLast()
                builders[id] = nil
                schedulers[id] = nil
            }
            return TurnSnapshot(prefix: "", tail: "", committed: false)
        }
        // A missing diarizer slot must not reserve a raw id. Slot 0 is the first speaker.
        let ordinal: Int?
        if let speakerRaw {
            ordinal = speakers.ordinal(for: speakerRaw)
        } else {
            ordinal = nil
        }
        if turns.isEmpty || turns[turns.count - 1].committed {
            beginTurn(ordinal: ordinal, at: now)
        } else if let ordinal {
            retargetOpenTurn(ordinal: ordinal)
        }
        let index = turns.count - 1
        var builder = builders[turns[index].id] ?? TurnBuilder()
        let snapshot = builder.ingest(hypothesis: hypothesis, at: now, endpoint: endpoint)
        builders[turns[index].id] = builder
        turns[index].sourcePrefix = snapshot.prefix
        turns[index].sourceTail = snapshot.tail
        var scheduler = schedulers[turns[index].id] ?? TranslationScheduler()
        scheduler.noteChunk()
        schedulers[turns[index].id] = scheduler
        copyTranslation(to: index)
        if endpoint {
            finishTurn(at: index, now: now)
        } else {
            requestTranslation(
                turnID: turns[index].id,
                sourcePrefix: snapshot.prefix,
                endpoint: false,
                now: now
            )
        }
        return snapshot
    }

    /// About one second of overlap retargets the open chip. It does not lock the
    /// first speaker onto the turn, and it does not merge a locked turn.
    mutating func overlap(speakerRaw: Int, seconds: TimeInterval) {
        guard seconds <= 1.5, let index = turns.indices.last, !turns[index].committed else { return }
        let ordinal = speakers.ordinal(for: speakerRaw)
        retargetOpenTurn(ordinal: ordinal)
    }

    mutating func rename(turnID: String, to name: String) {
        guard let turn = turns.first(where: { $0.id == turnID }),
              let ordinal = turn.speakerOrdinal,
              ordinal >= 1 else { return }
        rename(ordinal: ordinal, to: name)
    }

    mutating func rename(ordinal: Int, to name: String) {
        speakers.rename(ordinal: ordinal, to: name)
        for index in turns.indices where turns[index].speakerOrdinal == min(max(ordinal, 1), SpeakerTrack.cap) {
            turns[index].speakerLabel = speakers.label(for: ordinal)
        }
    }

    mutating func highlightCurrent(now: Date) {
        guard let turn = turns.last(where: { !$0.sourcePrefix.isEmpty || !$0.sourceTail.isEmpty }) ?? turns.last else {
            return
        }
        let text = turn.committed ? turn.translationCommitted : turn.sourcePrefix
        let shown = text.isEmpty ? turn.sourceDisplay : text
        notes.highlight(turnID: turn.id, text: shown, speaker: turn.speakerLabel)
        focusedTurnID = turn.id
        _ = now
    }

    @discardableResult
    mutating func deliverTranslation(generation: Int, text: String, at now: Date) -> Bool {
        guard let turnID = pendingTranslation?.turnID else { return false }
        let turnCommitted = turns.first { $0.id == turnID }?.committed ?? false
        let endpoint = (pendingTranslation?.endpoint ?? false) || turnCommitted
        var scheduler = schedulers[turnID] ?? TranslationScheduler()
        let accepted = scheduler.deliver(generation: generation, translation: text, endpoint: endpoint)
        schedulers[turnID] = scheduler
        pendingTranslation = nil
        if accepted {
            retryTurnID = nil
            if let index = turns.firstIndex(where: { $0.id == turnID }) {
                copyTranslation(to: index)
                if turns[index].committed {
                    notes.upsert(
                        id: turns[index].id,
                        translation: turns[index].translationCommitted,
                        speaker: turns[index].speakerLabel,
                        now: now
                    )
                }
            }
            promoteWaiting(at: now)
            if pendingTranslation == nil {
                notes.setTranslationInFlight(schedulers.values.contains { $0.inFlight }, now: now)
            }
        } else {
            retryTurnID = turnID
            notes.setTranslationInFlight(scheduler.inFlight, now: now)
        }
        return accepted
    }

    /// An endpoint that arrived while a translation was in flight is asked again
    /// after the stale result is dropped. The retry stays on the turn that owned
    /// the request. A pack that is not installed never reaches this.
    mutating func retryTranslation(at now: Date) -> TranslationRequest? {
        guard pendingTranslation == nil else { return nil }
        let turnID = retryTurnID ?? turns.last?.id
        retryTurnID = nil
        guard let turnID, let index = turns.firstIndex(where: { $0.id == turnID }) else { return nil }
        let turn = turns[index]
        guard !turn.sourcePrefix.isEmpty else { return nil }
        var scheduler = schedulers[turnID] ?? TranslationScheduler()
        guard let request = scheduler.consider(
            turnID: turn.id,
            sourcePrefix: turn.sourcePrefix,
            direction: direction,
            endpoint: turn.committed
        ) else {
            schedulers[turnID] = scheduler
            return nil
        }
        schedulers[turnID] = scheduler
        pendingTranslation = request
        notes.setTranslationInFlight(true, now: now)
        return request
    }

    mutating func stop(at now: Date) {
        listening = false
        if let index = turns.indices.last, !turns[index].committed {
            _ = pushHypothesis(turns[index].sourceDisplay, speakerRaw: rawForOpenTurn(), at: now, endpoint: true)
        }
        notes.stop(now: now)
    }

    mutating func tick(now: Date) {
        notes.tick(now: now)
    }

    func saveDocument() -> TranscriptSave {
        let saved = turns.map { turn in
            SavedTurn(
                id: turn.id,
                source: turn.sourcePrefix,
                translation: turn.translationCommitted,
                speaker: turn.speakerLabel,
                start: turn.start,
                end: turn.end ?? turn.start,
                direction: turn.direction.rawValue
            )
        }
        return TranscriptSave(direction: direction.rawValue, turns: saved, note: notes.note)
    }

    private mutating func beginTurn(ordinal: Int?, at now: Date) {
        let id = "t\(nextTurnNumber)"
        nextTurnNumber += 1
        let origin = sessionStarted ?? now
        let turn = SessionTurn(
            id: id,
            speakerOrdinal: ordinal,
            speakerLabel: ordinal.map { speakers.label(for: $0) } ?? "",
            speakerLocked: false,
            sourcePrefix: "",
            sourceTail: "",
            translationCommitted: "",
            translationProvisional: "",
            start: now.timeIntervalSince(origin),
            end: nil,
            committed: false,
            direction: direction
        )
        turns.append(turn)
        builders[id] = TurnBuilder()
        schedulers[id] = TranslationScheduler()
    }

    private mutating func retargetOpenTurn(ordinal: Int) {
        guard let index = turns.indices.last, !turns[index].speakerLocked else { return }
        turns[index].speakerOrdinal = ordinal
        turns[index].speakerLabel = speakers.label(for: ordinal)
    }

    private mutating func finishTurn(at index: Int, now: Date) {
        let origin = sessionStarted ?? now
        turns[index].committed = true
        turns[index].speakerLocked = true
        turns[index].sourceTail = ""
        turns[index].end = now.timeIntervalSince(origin)
        let id = turns[index].id
        let wasInFlight = schedulers[id]?.inFlight ?? false
        requestTranslation(turnID: id, sourcePrefix: turns[index].sourcePrefix, endpoint: true, now: now)
        let queued = turnsAwaitingTranslation.contains(id)
        let nowInFlight = schedulers[id]?.inFlight ?? false
        if !wasInFlight && !nowInFlight && !queued {
            notes.upsert(
                id: turns[index].id,
                translation: turns[index].translationCommitted,
                speaker: turns[index].speakerLabel,
                now: now
            )
        }
    }

    /// One translation at a time. A request that is already in flight stays bound
    /// to its turn when the next utterance starts. A later turn that is due waits.
    private mutating func requestTranslation(turnID: String, sourcePrefix: String, endpoint: Bool, now: Date) {
        let ownsFlight = pendingTranslation?.turnID == turnID || schedulers[turnID]?.inFlight == true
        let pendingOther = pendingTranslation.map { $0.turnID != turnID } ?? false
        let schedulerOther = schedulers.contains { $0.key != turnID && $0.value.inFlight }
        if !ownsFlight && (pendingOther || schedulerOther) {
            let probe = schedulers[turnID] ?? TranslationScheduler()
            if probe.isDue(sourcePrefix: sourcePrefix, direction: direction, endpoint: endpoint),
               !turnsAwaitingTranslation.contains(turnID) {
                turnsAwaitingTranslation.append(turnID)
            }
            return
        }
        var scheduler = schedulers[turnID] ?? TranslationScheduler()
        if let request = scheduler.consider(
            turnID: turnID,
            sourcePrefix: sourcePrefix,
            direction: direction,
            endpoint: endpoint
        ) {
            pendingTranslation = request
            notes.setTranslationInFlight(true, now: now)
        }
        schedulers[turnID] = scheduler
    }

    private mutating func promoteWaiting(at now: Date) {
        while !turnsAwaitingTranslation.isEmpty {
            let id = turnsAwaitingTranslation.removeFirst()
            guard let index = turns.firstIndex(where: { $0.id == id }) else { continue }
            let turn = turns[index]
            var scheduler = schedulers[id] ?? TranslationScheduler()
            if let request = scheduler.consider(
                turnID: id,
                sourcePrefix: turn.sourcePrefix,
                direction: direction,
                endpoint: turn.committed
            ) {
                schedulers[id] = scheduler
                pendingTranslation = request
                notes.setTranslationInFlight(true, now: now)
                copyTranslation(to: index)
                return
            }
            schedulers[id] = scheduler
        }
    }

    private mutating func copyTranslation(to index: Int) {
        let scheduler = schedulers[turns[index].id] ?? TranslationScheduler()
        turns[index].translationCommitted = scheduler.committed
        turns[index].translationProvisional = scheduler.provisional
    }

    private func rawForOpenTurn() -> Int? {
        guard let ordinal = turns.last?.speakerOrdinal, ordinal >= 1 else { return nil }
        return speakers.raw(forOrdinal: ordinal)
    }
}

protocol SpeakerLabeling {
    /// Nil until the diarizer emits a speaker slot. Callers must not invent a raw id.
    mutating func speakerRaw(pcm: [Float]) -> Int?
}
