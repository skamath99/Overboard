import XCTest
@testable import PushFightCore

private func p(_ notation: String) -> Position {
    Position(notation)!
}

final class GameRecordTests: XCTestCase {
    private func openingRecord() throws -> GameRecord {
        var record = GameRecord()
        for (kind, tile) in [("square", "d2"), ("square", "d3"), ("square", "d1"), ("round", "c2"), ("round", "c3"),
                             ("square", "e2"), ("square", "e3"), ("square", "e1"), ("round", "f2"), ("round", "f3")] {
            try record.apply(.place(PieceKind(rawValue: kind)!, at: p(tile)))
        }
        return record
    }

    func testApplyValidatesAndAppends() throws {
        var record = try openingRecord()
        XCTAssertEqual(record.actions.count, 10)
        try record.apply(.move(from: p("c2"), to: p("c1")))
        XCTAssertEqual(record.actions.count, 11)
        // Invalid actions neither mutate state nor append.
        XCTAssertThrowsError(try record.apply(.move(from: p("f2"), to: p("g2"))))
        XCTAssertEqual(record.actions.count, 11)
        XCTAssertEqual(record.state.movesUsed, 1)
    }

    func testUndoLastAction() throws {
        var record = try openingRecord()
        let before = record.state
        try record.apply(.move(from: p("c2"), to: p("c1")))
        record.undoLastAction()
        XCTAssertEqual(record.state, before)
        XCTAssertEqual(record.actions.count, 10)
    }

    func testReplayScrubbing() throws {
        var record = try openingRecord()
        try record.apply(.move(from: p("c2"), to: p("c1")))
        try record.apply(.push(from: p("d2"), .right))

        XCTAssertEqual(record.state(afterActions: 0), GameState())
        XCTAssertEqual(record.state(afterActions: 10).phase, .playing)
        XCTAssertNil(record.state(afterActions: 11).piece(at: p("c2")))
        XCTAssertEqual(record.state(afterActions: 12), record.state)
        // Out-of-range counts clamp instead of crashing.
        XCTAssertEqual(record.state(afterActions: 99), record.state)
    }

    func testSerializationRoundTripRebuildsState() throws {
        var record = try openingRecord()
        try record.apply(.push(from: p("d2"), .right))
        let decoded = try GameRecord(serialized: record.serialized())
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.state, record.state)
    }

    func testCorruptLogFailsToDecode() throws {
        // A log whose second action is illegal must be rejected wholesale.
        XCTAssertThrowsError(try GameRecord(actions: [
            .place(.square, at: p("d2")),
            .place(.square, at: p("d2")),
        ]))
    }
}

final class EloTests: XCTestCase {
    func testExpectedScoreProperties() {
        XCTAssertEqual(Elo.expectedScore(1200, against: 1200), 0.5, accuracy: 0.0001)
        // 400 points of advantage ≈ 10:1 odds.
        XCTAssertEqual(Elo.expectedScore(1600, against: 1200), 10.0 / 11.0, accuracy: 0.0001)
        XCTAssertEqual(
            Elo.expectedScore(1500, against: 1300) + Elo.expectedScore(1300, against: 1500),
            1.0,
            accuracy: 0.0001
        )
    }

    func testEqualRatingsExchangeHalfK() {
        let (w, l) = Elo.updatedRatings(winner: 1200, loser: 1200)
        XCTAssertEqual(w, 1216)
        XCTAssertEqual(l, 1184)
    }

    func testUpsetTransfersMorePoints() {
        let upset = Elo.updatedRatings(winner: 1200, loser: 1600)
        let expected = Elo.updatedRatings(winner: 1600, loser: 1200)
        XCTAssertGreaterThan(upset.winner - 1200, expected.winner - 1600)
        // Rating is conserved.
        XCTAssertEqual(upset.winner + upset.loser, 2800)
    }
}
