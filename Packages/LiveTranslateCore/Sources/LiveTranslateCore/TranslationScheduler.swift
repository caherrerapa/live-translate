import Foundation

struct TranslationRequest: Equatable {
    var generation: Int
    var turnID: String
    var source: String
    var direction: TranslationDirection
    var endpoint: Bool

    var prompt: String {
        TranslationPrompt.text(source: source, direction: direction)
    }
}

/// Translates the current turn only. A call starts when the committed source
/// grows by about 12 Thai characters or about 4 English words, or at endpoint.
/// One call at a time. A result for a prefix that already moved is dropped.
/// The committed translation does not jump. A provisional line becomes committed
/// after it is unchanged across one more chunk, or at endpoint.
struct TranslationScheduler {
    private(set) var committed = ""
    private(set) var provisional = ""
    private(set) var inFlight = false
    private var generation = 0
    private var inFlightGeneration = 0
    private var inFlightSource = ""
    private var invalidatedGeneration = 0
    private var countedUnits = 0
    private var lastDelivered = ""
    private var sawDelivery = false
    /// A finished endpoint is not asked again. Asking it again would loop.
    private var endpointSatisfied = false

    static let thaiCharacterThreshold = 12
    static let englishWordThreshold = 4

    mutating func reset() {
        committed = ""
        provisional = ""
        inFlight = false
        inFlightSource = ""
        countedUnits = 0
        lastDelivered = ""
        sawDelivery = false
        endpointSatisfied = false
    }

    func isDue(sourcePrefix: String, direction: TranslationDirection, endpoint: Bool) -> Bool {
        if endpointSatisfied || inFlight { return false }
        return Self.due(sourcePrefix: sourcePrefix, countedUnits: countedUnits, direction: direction, endpoint: endpoint)
    }

    mutating func consider(
        turnID: String,
        sourcePrefix: String,
        direction: TranslationDirection,
        endpoint: Bool
    ) -> TranslationRequest? {
        guard !endpointSatisfied else { return nil }
        let units = Self.units(sourcePrefix, language: direction.source)
        let due = Self.due(
            sourcePrefix: sourcePrefix,
            countedUnits: countedUnits,
            direction: direction,
            endpoint: endpoint
        )
        guard due else { return nil }
        if inFlight {
            if sourcePrefix != inFlightSource {
                invalidatedGeneration = inFlightGeneration
            }
            return nil
        }
        generation += 1
        inFlight = true
        inFlightGeneration = generation
        inFlightSource = sourcePrefix
        countedUnits = units
        return TranslationRequest(
            generation: generation,
            turnID: turnID,
            source: sourcePrefix,
            direction: direction,
            endpoint: endpoint
        )
    }

    /// The next recognizer chunk. An unchanged provisional translation commits.
    mutating func noteChunk() {
        guard !inFlight, sawDelivery, !provisional.isEmpty else { return }
        guard committed + provisional == lastDelivered else { return }
        committed = lastDelivered
        provisional = ""
    }

    @discardableResult
    mutating func deliver(generation: Int, translation: String, endpoint: Bool) -> Bool {
        guard generation == inFlightGeneration, inFlight else { return false }
        inFlight = false
        if generation == invalidatedGeneration {
            return false
        }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint {
            // The flush is the translation of the whole turn. It replaces the partials.
            // A failed call (empty text) keeps what was already shown.
            if !text.isEmpty {
                committed = text
            } else {
                committed += provisional
            }
            provisional = ""
            sawDelivery = true
            lastDelivered = committed
            endpointSatisfied = true
            return true
        }
        guard !text.isEmpty else { return true }
        sawDelivery = true
        lastDelivered = text
        // A translation of a longer prefix is free to reword the earlier words.
        // The committed part keeps only what the new translation still agrees with,
        // so the panel always reads as the latest translation and never drops it.
        if !text.hasPrefix(committed) {
            committed = Self.commonPrefix(committed, text)
        }
        provisional = String(text.dropFirst(committed.count))
        return true
    }

    private static func commonPrefix(_ left: String, _ right: String) -> String {
        var count = 0
        for (a, b) in zip(left, right) {
            if a != b { break }
            count += 1
        }
        return String(left.prefix(count))
    }

    private static func due(
        sourcePrefix: String,
        countedUnits: Int,
        direction: TranslationDirection,
        endpoint: Bool
    ) -> Bool {
        let units = units(sourcePrefix, language: direction.source)
        let growth = max(0, units - countedUnits)
        // Unspaced scripts (Thai, Chinese, Japanese) grow by characters; the rest by words.
        let threshold = direction.source.countsCharacters ? thaiCharacterThreshold : englishWordThreshold
        return endpoint ? !sourcePrefix.isEmpty : growth >= threshold
    }

    static func units(_ text: String, language: SpeechLanguage) -> Int {
        if language.countsCharacters {
            return text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        return text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
