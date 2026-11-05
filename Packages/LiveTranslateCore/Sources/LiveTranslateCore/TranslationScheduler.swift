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
        guard provisional == lastDelivered else { return }
        guard committed.isEmpty || provisional.hasPrefix(committed) else { return }
        committed = provisional
        provisional = ""
    }

    @discardableResult
    mutating func deliver(generation: Int, translation: String, endpoint: Bool) -> Bool {
        guard generation == inFlightGeneration, inFlight else { return false }
        inFlight = false
        if generation == invalidatedGeneration {
            return false
        }
        sawDelivery = true
        lastDelivered = translation
        if endpoint {
            if committed.isEmpty || translation.hasPrefix(committed) {
                committed = translation
                provisional = ""
            }
            endpointSatisfied = true
            return true
        }
        if committed.isEmpty || translation.hasPrefix(committed) {
            provisional = String(translation.dropFirst(committed.count))
            if provisional.isEmpty {
                provisional = translation == committed ? "" : translation
            }
            // Keep the full latest translation as the provisional line until it commits.
            provisional = translation
        }
        return true
    }

    private static func due(
        sourcePrefix: String,
        countedUnits: Int,
        direction: TranslationDirection,
        endpoint: Bool
    ) -> Bool {
        let units = units(sourcePrefix, language: direction.source)
        let growth = max(0, units - countedUnits)
        let threshold = direction.source == .thai ? thaiCharacterThreshold : englishWordThreshold
        return endpoint ? !sourcePrefix.isEmpty : growth >= threshold
    }

    static func units(_ text: String, language: SpeechLanguage) -> Int {
        switch language {
        case .english:
            return text.split { $0.isWhitespace || $0.isNewline }.count
        case .thai:
            return text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
    }
}
