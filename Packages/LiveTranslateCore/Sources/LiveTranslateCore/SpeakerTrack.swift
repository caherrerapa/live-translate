import Foundation

/// Session labels only. Speaker 1 is the first voice that appears. The chip can
/// change until the endpoint, then it locks. A rename sticks for this session,
/// stores no voice, and disappears when the session is cleared. More than eight
/// speakers still transcribe; they share the eighth chip.
struct SpeakerTrack: Equatable {
    private(set) var names: [Int: String] = [:]
    private var rawToOrdinal: [Int: Int] = [:]
    private var nextOrdinal = 1
    var chipsVisible = true

    static let cap = PackPolicy.speakerCap

    mutating func ordinal(for raw: Int) -> Int {
        if let existing = rawToOrdinal[raw] {
            return existing
        }
        let assigned = min(nextOrdinal, Self.cap)
        rawToOrdinal[raw] = assigned
        if nextOrdinal <= Self.cap {
            nextOrdinal += 1
        }
        return assigned
    }

    func raw(forOrdinal ordinal: Int) -> Int? {
        let capped = min(max(ordinal, 1), Self.cap)
        return rawToOrdinal.first { $0.value == capped }?.key
    }

    func label(for ordinal: Int) -> String {
        let capped = min(max(ordinal, 1), Self.cap)
        return names[capped] ?? "Speaker \(capped)"
    }

    /// Nil when the turn has no diarizer slot yet. A real ordinal is a palette
    /// index in `0..<paletteCount`. The eighth speaker shares the last color.
    func colorIndex(ordinal: Int?, paletteCount: Int) -> Int? {
        guard let ordinal, ordinal >= 1, paletteCount > 0 else { return nil }
        return (min(ordinal, Self.cap) - 1) % paletteCount
    }

    mutating func rename(ordinal: Int, to name: String) {
        let capped = min(max(ordinal, 1), Self.cap)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        names[capped] = trimmed
    }

    mutating func clear() {
        names.removeAll()
        rawToOrdinal.removeAll()
        nextOrdinal = 1
        chipsVisible = true
    }
}
