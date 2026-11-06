import XCTest
@testable import LiveTranslateCore

/// Nemotron English revises punctuation on text that has already sat still
/// ("nine," becomes "nine. Please"). The turn must keep streaming and the
/// translation must cover the whole turn, not the first few words.
final class EnglishStreamTests: XCTestCase {
    private let hypotheses = [
        "Meeting starts",
        "Meeting starts at nine,",
        "Meeting starts at nine. Please send",
        "Meeting starts at nine. Please send the notes today.",
        "Meeting starts at nine. Please send the notes today. We decided to ship the",
        "Meeting starts at nine. Please send the notes today. We decided to ship the translation on this Mac.",
    ]

    func testRevisedPunctuationKeepsTheTurnAndTranslationStreaming() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try ModelCatalog.load(from: root.appendingPathComponent("docs/model-catalog.json"))
        var engine = SessionEngine(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            packInstalled: true,
            notes: NotesReducer { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        )
        engine.direction = .englishToThai
        engine.setListening(true)
        var now = Date(timeIntervalSince1970: 90_000)
        var requests: [String] = []
        // A 1120 ms chunk arrives as 28 mic buffers of 40 ms with the same hypothesis.
        for hypothesis in hypotheses {
            for _ in 0..<28 {
                engine.pushHypothesis(hypothesis, speakerRaw: nil, at: now, endpoint: false)
                if let request = engine.pendingTranslation {
                    requests.append(request.source)
                    engine.deliverTranslation(generation: request.generation, text: "T<\(request.source)>", at: now)
                }
                now = now.addingTimeInterval(0.04)
            }
            let turn = try XCTUnwrap(engine.turns.last)
            XCTAssertEqual(turn.sourcePrefix + turn.sourceTail, hypothesis)
        }
        XCTAssertGreaterThan(requests.count, 2)
        engine.pushHypothesis(hypotheses[hypotheses.count - 1], speakerRaw: nil, at: now, endpoint: true)
        while let request = engine.pendingTranslation {
            engine.deliverTranslation(generation: request.generation, text: "T<\(request.source)>", at: now)
        }
        let turn = try XCTUnwrap(engine.turns.last)
        XCTAssertTrue(turn.committed)
        XCTAssertEqual(turn.sourcePrefix, hypotheses[hypotheses.count - 1])
        XCTAssertEqual(turn.translationCommitted, "T<\(hypotheses[hypotheses.count - 1])>")
    }
}
