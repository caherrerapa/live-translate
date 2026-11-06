import Foundation

struct NoteItem: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var turnID: String
    var speaker: String
    var tentative: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case turnID = "turn_id"
        case speaker
        case tentative
    }
}

struct MeetingNote: Codable, Equatable {
    var title: NoteItem
    var summary: [NoteItem]
    var decisions: [NoteItem]
    var actions: [NoteItem]
    var openQuestions: [NoteItem]
    var highlights: [NoteItem]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case decisions
        case actions
        case openQuestions = "open_questions"
        case highlights
    }

    static func empty() -> MeetingNote {
        MeetingNote(
            title: NoteItem(id: "title", text: "", turnID: "", speaker: "", tentative: true),
            summary: [],
            decisions: [],
            actions: [],
            openQuestions: [],
            highlights: []
        )
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct NotesTurn: Equatable {
    var id: String
    var translation: String
    var speaker: String
    var folded: Bool
}

struct NotesInput: Equatable {
    var note: MeetingNote
    var turns: [NotesTurn]
}

struct DraftItem: Equatable {
    var text: String
    var turnID: String
    var speaker: String
    var contradictsTurnID: String?
}

struct NotesDraft: Equatable {
    var title: String
    var titleTurnID: String
    var summary: [DraftItem]
    var decisions: [DraftItem]
    var actions: [DraftItem]
    var openQuestions: [DraftItem]
}

enum NotesPassReason: String, Equatable {
    case timer
    case words
    case stop
}

/// Live notes. The model sees committed translation text only. An item stays
/// tentative until a later pass repeats it. Highlight pins a turn immediately.
/// A pass waits while a translation is in flight. Stop runs one last pass.
struct NotesReducer {
    var note: MeetingNote
    var model: (NotesInput) -> NotesDraft
    private(set) var turns: [NotesTurn] = []
    private(set) var passCount = 0
    private(set) var stopPassCount = 0
    private(set) var reasons: [NotesPassReason] = []
    private(set) var translationInFlight = false
    private var wordsSincePass = 0
    private var due: Date?
    private var stopArmed = false
    private var stopFinished = false
    private var deletedIDs: Set<String> = []

    static let emptyLine = "Notes appear as the conversation commits."
    static let wordThreshold = 120
    static let delaySeconds: TimeInterval = 8

    init(model: @escaping (NotesInput) -> NotesDraft) {
        self.note = .empty()
        self.model = model
    }

    mutating func setTranslationInFlight(_ inFlight: Bool, now: Date) {
        translationInFlight = inFlight
        guard !inFlight else { return }
        if stopArmed && !stopFinished {
            runPass(reason: .stop, now: now)
            stopFinished = true
            return
        }
        if wordsSincePass >= Self.wordThreshold {
            runPass(reason: .words, now: now)
        }
    }

    mutating func upsert(id: String, translation: String, speaker: String, now: Date) {
        if let index = turns.firstIndex(where: { $0.id == id }) {
            guard !turns[index].folded else { return }
            let previous = Self.wordCount(turns[index].translation)
            turns[index].translation = translation
            turns[index].speaker = speaker
            wordsSincePass += max(0, Self.wordCount(translation) - previous)
        } else {
            turns.append(NotesTurn(id: id, translation: translation, speaker: speaker, folded: false))
            wordsSincePass += Self.wordCount(translation)
        }
        schedule(now: now)
    }

    /// Pins the current turn before any notes pass.
    mutating func highlight(turnID: String, text: String, speaker: String) {
        guard !turnID.isEmpty else { return }
        guard !note.highlights.contains(where: { $0.turnID == turnID }) else { return }
        note.highlights.append(
            NoteItem(id: "highlight-\(turnID)", text: text, turnID: turnID, speaker: speaker, tentative: false)
        )
    }

    mutating func tick(now: Date) {
        guard !translationInFlight, !stopFinished else { return }
        guard let due, now >= due else { return }
        runPass(reason: .timer, now: now)
    }

    mutating func stop(now: Date) {
        guard !stopFinished, !stopArmed else { return }
        stopArmed = true
        if translationInFlight {
            return
        }
        runPass(reason: .stop, now: now)
        stopFinished = true
    }

    mutating func delete(itemID: String) {
        deletedIDs.insert(itemID)
        note.summary.removeAll { $0.id == itemID }
        note.decisions.removeAll { $0.id == itemID }
        note.actions.removeAll { $0.id == itemID }
        note.openQuestions.removeAll { $0.id == itemID }
        note.highlights.removeAll { $0.id == itemID }
    }

    func input(liveTail: String, audioPath: String?) -> NotesInput {
        _ = liveTail
        _ = audioPath
        let pending = turns.filter { !$0.folded }
        return NotesInput(note: note, turns: pending)
    }

    private mutating func schedule(now: Date) {
        guard !stopFinished else { return }
        if wordsSincePass >= Self.wordThreshold && !translationInFlight {
            runPass(reason: .words, now: now)
            return
        }
        due = now.addingTimeInterval(Self.delaySeconds)
    }

    private mutating func runPass(reason: NotesPassReason, now: Date) {
        guard !translationInFlight else { return }
        let pending = turns.filter { !$0.folded }
        if reason != .stop && pending.isEmpty {
            due = nil
            return
        }
        let draft = model(NotesInput(note: note, turns: pending))
        apply(draft)
        let pendingIDs = Set(pending.map(\.id))
        for index in turns.indices where pendingIDs.contains(turns[index].id) {
            turns[index].folded = true
        }
        passCount += 1
        reasons.append(reason)
        if reason == .stop {
            stopPassCount += 1
        }
        wordsSincePass = 0
        due = nil
        _ = now
    }

    private mutating func apply(_ draft: NotesDraft) {
        if !draft.title.isEmpty {
            note.title = mergeTitle(current: note.title, text: draft.title, turnID: draft.titleTurnID)
        }
        note.summary = merge(note.summary, draft.summary, section: "summary")
        note.decisions = merge(note.decisions, draft.decisions, section: "decision")
        note.actions = merge(note.actions, draft.actions, section: "action")
        note.openQuestions = merge(note.openQuestions, draft.openQuestions, section: "question")
    }

    private func mergeTitle(current: NoteItem, text: String, turnID: String) -> NoteItem {
        if current.text == text && !current.text.isEmpty {
            var locked = current
            locked.tentative = false
            if !turnID.isEmpty {
                locked.turnID = turnID
            }
            return locked
        }
        if !current.tentative && !current.text.isEmpty && current.text != text {
            return current
        }
        return NoteItem(id: "title", text: text, turnID: turnID, speaker: "", tentative: current.text != text)
    }

    private func merge(_ existing: [NoteItem], _ incoming: [DraftItem], section: String) -> [NoteItem] {
        var output = existing.filter { !deletedIDs.contains($0.id) }
        for item in incoming {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !item.turnID.isEmpty else { continue }
            if let index = output.firstIndex(where: { $0.text == text }) {
                output[index].tentative = false
                output[index].turnID = item.turnID
                output[index].speaker = item.speaker
                continue
            }
            if let contradicts = item.contradictsTurnID,
               let index = output.firstIndex(where: { !$0.tentative && $0.turnID == contradicts }) {
                output[index].text = text
                output[index].turnID = item.turnID
                output[index].speaker = item.speaker
                continue
            }
            if output.contains(where: { !$0.tentative && $0.turnID == item.turnID && $0.text != text }) {
                continue
            }
            let id = "\(section)-\(item.turnID)-\(output.count + 1)"
            guard !deletedIDs.contains(id) else { continue }
            output.append(NoteItem(id: id, text: text, turnID: item.turnID, speaker: item.speaker, tentative: true))
        }
        return output
    }

    static func wordCount(_ text: String) -> Int {
        let parts = text.split { $0.isWhitespace || $0.isNewline }
        if parts.count > 1 || text.contains(where: { $0.isWhitespace }) {
            return parts.count
        }
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return scalars / 6
    }
}

enum NotesProductionPass {
    /// The Mac and iPhone notes closures call this. A draft whose text is only
    /// the committed translation is dropped. Paraphrases stay.
    static func produce(input: NotesInput, generate: (NotesInput) -> NotesDraft) -> NotesDraft {
        sanitize(generate(input), input: input)
    }

    static func sanitize(_ draft: NotesDraft, input: NotesInput) -> NotesDraft {
        let banned = Set(input.turns.map { normalize($0.translation) }.filter { !$0.isEmpty })
        func allowed(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !banned.contains(normalize(trimmed)) else { return nil }
            return trimmed
        }
        func keep(_ items: [DraftItem]) -> [DraftItem] {
            items.compactMap { item in
                guard let text = allowed(item.text) else { return nil }
                return DraftItem(
                    text: text,
                    turnID: item.turnID,
                    speaker: item.speaker,
                    contradictsTurnID: item.contradictsTurnID
                )
            }
        }
        return NotesDraft(
            title: allowed(draft.title) ?? "",
            titleTurnID: draft.titleTurnID,
            summary: keep(draft.summary),
            decisions: keep(draft.decisions),
            actions: keep(draft.actions),
            openQuestions: keep(draft.openQuestions)
        )
    }

    static func prompt(for input: NotesInput) -> String {
        var lines = [
            "You maintain a live meeting note from committed turns.",
            "Write in the language of those turns.",
            "Return one JSON object and no other text.",
            "Keys: title, title_turn_id, summary, decisions, actions, open_questions.",
            "summary, decisions, actions, and open_questions are arrays of objects with keys text and turn_id.",
            "title is a short noun phrase. Do not copy a turn. Each item must be shorter than its turn and must not repeat the turn verbatim.",
            "Example of a later pass. Previous strings stay character for character, then a shorter new item is added.",
            "Previous title: Kickoff",
            "Previous summary:",
            "t0 | Kickoff set",
            "Previous decisions:",
            "(none)",
            "Previous actions:",
            "(none)",
            "Previous questions:",
            "(none)",
            "Turns:",
            "t9 | Speaker 1 | The team moved the kickoff to Tuesday.",
            "{\"title\":\"Kickoff\",\"title_turn_id\":\"t0\",\"summary\":[{\"text\":\"Kickoff set\",\"turn_id\":\"t0\"},{\"text\":\"Kickoff moved to Tuesday\",\"turn_id\":\"t9\"}],\"decisions\":[],\"actions\":[],\"open_questions\":[]}",
            "When a previous item is still true, repeat that item's text exactly.",
            "",
            "Previous title: \(input.note.title.text)",
        ]
        func dump(_ name: String, _ items: [NoteItem]) {
            lines.append(name)
            if items.isEmpty {
                lines.append("(none)")
            }
            for item in items where !item.text.isEmpty {
                lines.append("\(item.turnID) | \(item.text)")
            }
        }
        dump("Previous summary:", input.note.summary)
        dump("Previous decisions:", input.note.decisions)
        dump("Previous actions:", input.note.actions)
        dump("Previous questions:", input.note.openQuestions)
        lines.append("Turns:")
        if input.turns.isEmpty {
            lines.append("(none)")
        }
        for turn in input.turns {
            lines.append("\(turn.id) | \(turn.speaker) | \(turn.translation)")
        }
        return lines.joined(separator: "\n")
    }

    static func draft(parsing text: String, fallbackTurnID: String) -> NotesDraft {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              let data = String(cleaned[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
        }
        func items(_ key: String) -> [DraftItem] {
            let rows = object[key] as? [[String: Any]] ?? []
            return rows.compactMap { row in
                let itemText = row["text"] as? String ?? ""
                let turnID = (row["turn_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTurnID
                guard !itemText.isEmpty, !turnID.isEmpty else { return nil }
                return DraftItem(text: itemText, turnID: turnID, speaker: "", contradictsTurnID: nil)
            }
        }
        let titleTurn = (object["title_turn_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTurnID
        return NotesDraft(
            title: object["title"] as? String ?? "",
            titleTurnID: titleTurn,
            summary: items("summary"),
            decisions: items("decisions"),
            actions: items("actions"),
            openQuestions: items("open_questions")
        )
    }

    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = trimmed.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
