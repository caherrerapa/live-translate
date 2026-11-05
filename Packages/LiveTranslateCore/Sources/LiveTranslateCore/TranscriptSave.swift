import Foundation

struct SavedTurn: Codable, Equatable {
    var id: String
    var source: String
    var translation: String
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var direction: String
}

struct TranscriptSave: Codable, Equatable {
    var direction: String
    var turns: [SavedTurn]
    var note: MeetingNote

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func plainText() -> String {
        var lines: [String] = []
        lines.append(direction)
        for turn in turns {
            let span = String(format: "%.1f–%.1f", turn.start, turn.end)
            lines.append("\(turn.speaker) \(span) \(turn.direction)")
            lines.append(turn.source)
            if !turn.translation.isEmpty {
                lines.append(turn.translation)
            }
        }
        if !note.title.text.isEmpty {
            lines.append(note.title.text)
        }
        for item in note.summary + note.decisions + note.actions + note.openQuestions {
            lines.append("\(item.text) [\(item.turnID)]")
        }
        return lines.joined(separator: "\n")
    }
}
