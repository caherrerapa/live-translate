import Foundation

struct TurnSnapshot: Equatable {
    var prefix: String
    var tail: String
    var committed: Bool

    var display: String {
        committed ? prefix : prefix + tail
    }
}

struct StreamStep: Equatable {
    var text: String
    var endpoint: Bool
}

protocol PartialDecoding {
    mutating func decode(pcm: [Float]) -> StreamStep
}

/// Cache-aware partials: a committed prefix that only grows, a replaceable tail,
/// and an endpoint that commits the turn. Agreement across two hypotheses commits
/// the shared prefix. Text that sits still for 0.4 s commits as well. Thai is not
/// split on spaces.
struct TurnBuilder {
    private(set) var prefix = ""
    private(set) var tail = ""
    private(set) var committed = false
    private var previous = ""
    private var havePrevious = false
    private var stableSince: Date?

    static let stabilitySeconds: TimeInterval = 0.4

    mutating func ingest(hypothesis: String, at now: Date, endpoint: Bool) -> TurnSnapshot {
        if committed {
            return snapshot
        }
        if endpoint {
            // The recognizer's final text is the turn. An empty final keeps what was shown.
            let final = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty {
                prefix = hypothesis
            } else {
                prefix += tail
            }
            tail = ""
            committed = true
            previous = hypothesis
            havePrevious = true
            return snapshot
        }

        var nextPrefix = prefix
        // English output carries punctuation and casing that the recognizer revises
        // ("nine," becomes "nine. Please"). A revision that keeps most of the committed
        // prefix pulls the prefix back to the agreement, so the turn keeps streaming.
        // A hypothesis that contradicts nearly all of it is treated as a glitch.
        if !hypothesis.hasPrefix(prefix) {
            let agreement = Self.commonPrefix(prefix, hypothesis)
            if agreement.count * 2 >= prefix.count {
                nextPrefix = agreement
            }
        }
        if havePrevious {
            let agreement = Self.commonPrefix(previous, hypothesis)
            if agreement.count > nextPrefix.count, agreement.hasPrefix(nextPrefix) {
                nextPrefix = agreement
            }
            if hypothesis == previous,
               let since = stableSince,
               now.timeIntervalSince(since) >= Self.stabilitySeconds,
               hypothesis.count > nextPrefix.count,
               hypothesis.hasPrefix(nextPrefix) {
                nextPrefix = hypothesis
            }
        }

        if hypothesis == previous {
            if stableSince == nil {
                stableSince = now
            }
        } else {
            stableSince = now
        }

        prefix = nextPrefix
        if hypothesis.hasPrefix(prefix) {
            tail = String(hypothesis.dropFirst(prefix.count))
        }
        previous = hypothesis
        havePrevious = true
        return snapshot
    }

    private var snapshot: TurnSnapshot {
        TurnSnapshot(prefix: prefix, tail: tail, committed: committed)
    }

    private static func commonPrefix(_ left: String, _ right: String) -> String {
        let paired = zip(left, right)
        var count = 0
        for (a, b) in paired {
            if a != b { break }
            count += 1
        }
        return String(left.prefix(count))
    }
}

struct SpeechStream {
    private var builder = TurnBuilder()

    var prefix: String { builder.prefix }
    var tail: String { builder.tail }
    var committed: Bool { builder.committed }

    mutating func push<Decoder: PartialDecoding>(
        buffer: AudioBuffer,
        decoder: inout Decoder,
        at now: Date
    ) -> TurnSnapshot {
        let step = decoder.decode(pcm: buffer.samples)
        return builder.ingest(hypothesis: step.text, at: now, endpoint: step.endpoint)
    }
}
