import Foundation

/// Which text a subtitle file carries.
enum SubtitleText: String, CaseIterable, Identifiable {
    case translation
    case original
    case both

    var id: String { rawValue }
}

extension SessionRecord {
    // MARK: Subtitles

    /// SubRip (.srt): numbered cues with `00:01:02,500 --> 00:01:05,000` times from each turn.
    func srt(_ text: SubtitleText = .translation) -> String {
        cues(text).enumerated().map { index, cue in
            "\(index + 1)\n\(Self.stamp(cue.start, comma: true)) --> \(Self.stamp(cue.end, comma: true))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// WebVTT (.vtt), with the speaker as a voice tag so players can show who is talking.
    func webVTT(_ text: SubtitleText = .translation) -> String {
        var lines = ["WEBVTT", ""]
        for cue in cues(text) {
            lines.append("\(Self.stamp(cue.start, comma: false)) --> \(Self.stamp(cue.end, comma: false))")
            let body = cue.text.replacingOccurrences(of: "<", with: "&lt;")
            lines.append(cue.speaker.isEmpty ? body : "<v \(cue.speaker)>\(body)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String
        var text: String
    }

    /// Turns in time order. Each cue lasts from its turn's start to its end, at least 1 s so short
    /// turns stay readable, and never past the next turn's start, so cues don't overlap.
    private func cues(_ text: SubtitleText) -> [Cue] {
        let ordered = turns.sorted { $0.start < $1.start }
        var cues: [Cue] = []
        for (index, turn) in ordered.enumerated() {
            let body: String
            switch text {
            case .translation: body = turn.translation.isEmpty ? turn.source : turn.translation
            case .original: body = turn.source
            case .both: body = turn.translation.isEmpty ? turn.source : "\(turn.source)\n\(turn.translation)"
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let start = max(0, turn.start)
            let next = index + 1 < ordered.count ? ordered[index + 1].start : .infinity
            var end = min(max(turn.end, start + 1), next)
            if end <= start { end = start + 0.5 }
            cues.append(Cue(start: start, end: end, speaker: turn.speaker, text: trimmed))
        }
        return cues
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (WebVTT).
    static func stamp(_ seconds: TimeInterval, comma: Bool) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", ms)
    }
}
