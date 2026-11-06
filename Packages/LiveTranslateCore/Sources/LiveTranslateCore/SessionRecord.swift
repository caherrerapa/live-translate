import Foundation

/// One session in the history sidebar. Text only: turns, speaker labels, times,
/// the note, and the user's own notes. Audio is never part of a record.
struct SessionRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var started: Date
    var duration: TimeInterval
    var direction: TranslationDirection
    var turns: [SavedTurn]
    var note: MeetingNote
    var userNotes: String
    var checkedActions: Set<String>

    init(
        id: UUID = UUID(),
        title: String = "",
        started: Date,
        duration: TimeInterval = 0,
        direction: TranslationDirection,
        turns: [SavedTurn] = [],
        note: MeetingNote = .empty(),
        userNotes: String = "",
        checkedActions: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.started = started
        self.duration = duration
        self.direction = direction
        self.turns = turns
        self.note = note
        self.userNotes = userNotes
        self.checkedActions = checkedActions
    }

    /// The user's title, then the note's title, then the start time.
    var displayTitle: String {
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let noted = note.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !noted.isEmpty { return noted }
        return "Session " + started.formatted(date: .omitted, time: .shortened)
    }

    var speakerCount: Int {
        Set(turns.map(\.speaker).filter { !$0.isEmpty }).count
    }

    var isEmpty: Bool { turns.isEmpty && userNotes.isEmpty }

    var directionShort: String {
        "\(direction.source.short) → \(direction.target.short)"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if displayTitle.localizedCaseInsensitiveContains(needle) { return true }
        if userNotes.localizedCaseInsensitiveContains(needle) { return true }
        return turns.contains {
            $0.source.localizedCaseInsensitiveContains(needle) || $0.translation.localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: Export

    func markdown() -> String {
        var lines = ["# \(displayTitle)", ""]
        lines.append("\(started.formatted(date: .abbreviated, time: .shortened)) · \(directionShort) · \(Self.durationText(duration)) · \(speakerCount) speakers")
        lines.append("")
        lines.append(contentsOf: noteMarkdown())
        lines.append("## Transcript")
        lines.append("")
        for turn in turns {
            let clock = started.addingTimeInterval(turn.start).formatted(date: .omitted, time: .shortened)
            let speaker = turn.speaker.isEmpty ? "" : "**\(turn.speaker)** "
            lines.append("\(speaker)\(clock)  ")
            lines.append(turn.source + "  ")
            if !turn.translation.isEmpty {
                lines.append("_\(turn.translation)_")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func noteMarkdown() -> [String] {
        var lines: [String] = []
        let summary = note.summary.map(\.text).joined(separator: " ")
        if !summary.isEmpty {
            lines += ["## Summary", "", summary, ""]
        }
        let points = note.decisions + note.openQuestions + note.highlights
        if !points.isEmpty {
            lines += ["## Key points", ""]
            lines += points.map { "- \($0.text)" }
            lines.append("")
        }
        if !note.actions.isEmpty {
            lines += ["## Action items", ""]
            lines += note.actions.map { "- [\(checkedActions.contains($0.id) ? "x" : " ")] \($0.text)\($0.speaker.isEmpty ? "" : " (\($0.speaker))")" }
            lines.append("")
        }
        let own = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            lines += ["## Notes", "", own, ""]
        }
        return lines
    }

    func plainText() -> String {
        TranscriptSave(direction: direction.rawValue, turns: turns, note: note).plainText()
            + (userNotes.isEmpty ? "" : "\n\n" + userNotes)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Sidebar grouping: Today, Yesterday, Earlier.
enum SessionGroup: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"

    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> SessionGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }
}

extension SessionEngine {
    /// The live session as a record, keeping the record's id, title, times, and the user's notes.
    func record(updating base: SessionRecord) -> SessionRecord {
        var record = base
        record.direction = direction
        record.turns = saveDocument().turns.filter { !$0.source.isEmpty }
        record.note = notes.note
        return record
    }
}

/// What "Copy this session" puts on the pasteboard.
enum SessionCopyKind: String, CaseIterable, Identifiable {
    case original
    case translation
    case bilingual
    case summary

    var id: String { rawValue }
}

struct SessionCopyOptions: Equatable {
    var speakerNames = true
    var timestamps = false
    var markdown = false
}

extension SessionRecord {
    func copyText(_ kind: SessionCopyKind, options: SessionCopyOptions) -> String {
        if kind == .summary {
            let lines = noteMarkdown()
            guard options.markdown else {
                return lines
                    .map { $0.hasPrefix("## ") ? String($0.dropFirst(3)) : $0 }
                    .map { $0.hasPrefix("- [ ] ") || $0.hasPrefix("- [x] ") ? "• " + $0.dropFirst(6) : $0 }
                    .map { $0.hasPrefix("- ") ? "• " + $0.dropFirst(2) : $0 }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var blocks: [String] = []
        if options.markdown {
            blocks.append("# \(displayTitle)")
        }
        for turn in turns {
            var head: [String] = []
            if options.speakerNames, !turn.speaker.isEmpty {
                head.append(options.markdown ? "**\(turn.speaker)**" : turn.speaker)
            }
            if options.timestamps {
                head.append(started.addingTimeInterval(turn.start).formatted(date: .omitted, time: .shortened))
            }
            let lead = head.isEmpty ? "" : head.joined(separator: " · ")
            let body: [String]
            switch kind {
            case .original: body = [turn.source]
            case .translation: body = [turn.translation]
            case .bilingual: body = [turn.source, options.markdown ? "_\(turn.translation)_" : turn.translation]
            case .summary: body = []
            }
            let text = body.filter { !$0.isEmpty && $0 != "__" }
            guard !text.isEmpty else { continue }
            if lead.isEmpty {
                blocks.append(text.joined(separator: "\n"))
            } else if kind == .bilingual || options.markdown {
                blocks.append(([lead] + text).joined(separator: "\n"))
            } else {
                blocks.append("\(lead): \(text.joined(separator: "\n"))")
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}
