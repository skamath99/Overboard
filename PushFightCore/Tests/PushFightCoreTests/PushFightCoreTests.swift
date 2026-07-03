import XCTest
@testable import PushFightCore

private func p(_ notation: String) -> Position {
    Position(notation)!
}

final class BoardTests: XCTestCase {
    func testBoardHas26Tiles() {
        XCTAssertEqual(Board.allTiles.count, 26)
    }

    func testMissingCorners() {
        for notation in ["a1", "g1", "h1", "a4", "b4", "h4"] {
            XCTAssertFalse(Board.isTile(p(notation)), "\(notation) should be missing")
        }
        for notation in ["b1", "f1", "a2", "h2", "a3", "h3", "c4", "g4"] {
            XCTAssertTrue(Board.isTile(p(notation)), "\(notation) should exist")
        }
    }

    func testRailsRunAlongTopAndBottomRows() {
        XCTAssertEqual(Board.edge(from: p("c4"), .up), .rail)
        XCTAssertEqual(Board.edge(from: p("g4"), .up), .rail)
        XCTAssertEqual(Board.edge(from: p("b1"), .down), .rail)
        XCTAssertEqual(Board.edge(from: p("f1"), .down), .rail)
    }

    func testOpenEdges() {
        // Left and right ends of the board.
        XCTAssertEqual(Board.edge(from: p("a2"), .left), .off)
        XCTAssertEqual(Board.edge(from: p("h3"), .right), .off)
        // Gaps left by the missing corner squares.
        XCTAssertEqual(Board.edge(from: p("b3"), .up), .off)
        XCTAssertEqual(Board.edge(from: p("g2"), .down), .off)
        XCTAssertEqual(Board.edge(from: p("a2"), .down), .off)
        XCTAssertEqual(Board.edge(from: p("h3"), .up), .off)
    }

    func testNotationRoundTrip() {
        XCTAssertEqual(p("a1"), Position(column: 0, row: 0))
        XCTAssertEqual(p("h4"), Position(column: 7, row: 3))
        XCTAssertEqual(p("c2").notation, "c2")
        XCTAssertNil(Position("i1"))
        XCTAssertNil(Position("a5"))
    }
}

final class PlacementTests: XCTestCase {
    func testStandardSetupReachesPlayingPhase() throws {
        let state = try GameStateFixtures.standardOpening()
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.currentPlayer, .one)
        XCTAssertEqual(state.pieces.count, 10)
    }

    func testPlacementOrderAndBounds() throws {
        var state = GameState()
        XCTAssertEqual(state.placingPlayer, .one)
        // Player one cannot place on the opponent's half.
        XCTAssertThrowsError(try state.apply(.place(.square, at: p("e2")))) {
            XCTAssertEqual($0 as? GameError, .outsideHomeArea)
        }
        try state.apply(.place(.square, at: p("d2")))
        // Same tile twice is rejected.
        XCTAssertThrowsError(try state.apply(.place(.round, at: p("d2")))) {
            XCTAssertEqual($0 as? GameError, .tileOccupied)
        }
        // Piece counts are enforced: only 2 rounds per player.
        try state.apply(.place(.round, at: p("c2")))
        try state.apply(.place(.round, at: p("c3")))
        XCTAssertThrowsError(try state.apply(.place(.round, at: p("b2")))) {
            XCTAssertEqual($0 as? GameError, .noPieceOfThatKindLeft)
        }
    }
}

final class MoveTests: XCTestCase {
    func testMoveSlidesThroughEmptyTiles() throws {
        var state = try GameStateFixtures.standardOpening()
        // c2 winds through empty tiles (b2, b1) to reach b1 in a single move.
        try state.apply(.move(from: p("c2"), to: p("b1")))
        XCTAssertEqual(state.piece(at: p("b1")), Piece(owner: .one, kind: .round))
        XCTAssertNil(state.piece(at: p("c2")))
        XCTAssertEqual(state.movesRemaining, 1)
    }

    func testFullySurroundedPieceCannotMove() throws {
        let state = try GameStateFixtures.standardOpening()
        // d2's four neighbours (d1, d3, c2, e2) are all occupied.
        XCTAssertTrue(state.reachableTiles(from: p("d2")).isEmpty)
        XCTAssertThrowsError(try state.applying(.move(from: p("d2"), to: p("b2")))) {
            XCTAssertEqual($0 as? GameError, .destinationUnreachable)
        }
    }

    func testCannotMoveToMissingSquare() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "a2"), ("square", "b2"), ("square", "b3"), ("round", "c1"), ("round", "c2"),
        ], two: [
            ("square", "e2"), ("square", "f2"), ("square", "g2"), ("round", "f3"), ("round", "g3"),
        ])
        XCTAssertThrowsError(try state.apply(.move(from: p("a2"), to: p("a1")))) {
            XCTAssertEqual($0 as? GameError, .destinationUnreachable)
        }
    }

    func testAtMostTwoMovesPerTurn() throws {
        var state = try GameStateFixtures.standardOpening()
        try state.apply(.move(from: p("c2"), to: p("c1")))
        try state.apply(.move(from: p("c1"), to: p("b1")))
        XCTAssertThrowsError(try state.apply(.move(from: p("b1"), to: p("c1")))) {
            XCTAssertEqual($0 as? GameError, .noMovesRemaining)
        }
    }

    func testCannotMoveOpponentsPiece() throws {
        var state = try GameStateFixtures.standardOpening()
        XCTAssertThrowsError(try state.apply(.move(from: p("f2"), to: p("g2")))) {
            XCTAssertEqual($0 as? GameError, .notYourPiece)
        }
    }
}

final class PushTests: XCTestCase {
    func testPushShiftsLineAndPlacesAnchor() throws {
        var state = try GameStateFixtures.standardOpening()
        // Line d2, e2, f2 shifts right into empty g2.
        try state.apply(.push(from: p("d2"), .right))
        XCTAssertNil(state.piece(at: p("d2")))
        XCTAssertEqual(state.piece(at: p("e2")), Piece(owner: .one, kind: .square))
        XCTAssertEqual(state.piece(at: p("f2")), Piece(owner: .two, kind: .square))
        XCTAssertEqual(state.piece(at: p("g2")), Piece(owner: .two, kind: .round))
        XCTAssertEqual(state.anchor, p("e2"))
        XCTAssertEqual(state.currentPlayer, .two)
        XCTAssertEqual(state.movesUsed, 0)
    }

    func testRoundPiecesCannotPush() throws {
        var state = try GameStateFixtures.standardOpening()
        XCTAssertThrowsError(try state.apply(.push(from: p("c3"), .right))) {
            XCTAssertEqual($0 as? GameError, .onlySquaresCanPush)
        }
    }

    func testPushRequiresAdjacentPiece() throws {
        var state = try GameStateFixtures.standardOpening()
        // d4 is empty, so d3 has nothing to push upward.
        XCTAssertThrowsError(try state.apply(.push(from: p("d3"), .up))) {
            XCTAssertEqual($0 as? GameError, .nothingToPush)
        }
    }

    func testAnchorBlocksCounterPush() throws {
        var state = try GameStateFixtures.standardOpening()
        try state.apply(.push(from: p("d2"), .right))
        // Player two tries to push straight back into the anchored piece.
        XCTAssertThrowsError(try state.apply(.push(from: p("f2"), .left))) {
            XCTAssertEqual($0 as? GameError, .pushBlockedByAnchor)
        }
    }

    func testRailBlocksPush() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "c3"), ("square", "c4"), ("square", "b2"), ("round", "a2"), ("round", "a3"),
        ], two: [
            ("square", "f2"), ("square", "g2"), ("square", "g3"), ("round", "h2"), ("round", "h3"),
        ])
        // Pushing c3 up would shove c4 past the top rail.
        XCTAssertThrowsError(try state.apply(.push(from: p("c3"), .up))) {
            XCTAssertEqual($0 as? GameError, .pushBlockedByRail)
        }
    }

    func testPushOwnPieceOffLeftEdgeLosesTheGame() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "b2"), ("square", "b1"), ("square", "c1"), ("round", "a2"), ("round", "d2"),
        ], two: [
            ("square", "e2"), ("square", "f2"), ("square", "g2"), ("round", "f3"), ("round", "g3"),
        ])
        // b2 pushes its own round piece at a2 off the open left edge:
        // the fallen piece belongs to player one, so player two wins.
        try state.apply(.push(from: p("b2"), .left))
        XCTAssertEqual(state.phase, .finished(winner: .two))
    }

    func testPushOwnPieceOffThroughMissingCornerGap() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "b2"), ("square", "c2"), ("square", "d2"), ("round", "b3"), ("round", "c1"),
        ], two: [
            ("square", "e2"), ("square", "f2"), ("square", "g2"), ("round", "f3"), ("round", "g3"),
        ])
        // b2 pushes up: b3 is shoved into the missing b4 square and falls off.
        try state.apply(.push(from: p("b2"), .up))
        XCTAssertEqual(state.phase, .finished(winner: .two))
    }

    func testPushOpponentOffRightEdgeWinsTheGame() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "d2"), ("square", "a2"), ("square", "b1"), ("round", "b2"), ("round", "a3"),
        ], two: [
            ("square", "h2"), ("square", "h3"), ("square", "g4"), ("round", "f4"), ("round", "e4"),
        ])
        // Slide a square across the empty second row, then push h2 off the
        // open right edge. The fallen piece is player two's: player one wins.
        try state.apply(.move(from: p("d2"), to: p("g2")))
        try state.apply(.push(from: p("g2"), .right))
        XCTAssertEqual(state.phase, .finished(winner: .one))
    }

    func testChainPushMovesEveryPieceInLine() throws {
        var state = GameState()
        try GameStateFixtures.place(&state, one: [
            ("square", "c2"), ("round", "d2"), ("square", "b1"), ("square", "c1"), ("round", "d1"),
        ], two: [
            ("square", "e2"), ("round", "f2"), ("square", "g3"), ("square", "f3"), ("round", "g2"),
        ])
        // Line c2, d2, e2, f2, g2 shifts right into empty h2.
        try state.apply(.push(from: p("c2"), .right))
        XCTAssertNil(state.piece(at: p("c2")))
        XCTAssertEqual(state.piece(at: p("d2")), Piece(owner: .one, kind: .square))
        XCTAssertEqual(state.piece(at: p("e2")), Piece(owner: .one, kind: .round))
        XCTAssertEqual(state.piece(at: p("f2")), Piece(owner: .two, kind: .square))
        XCTAssertEqual(state.piece(at: p("g2")), Piece(owner: .two, kind: .round))
        XCTAssertEqual(state.piece(at: p("h2")), Piece(owner: .two, kind: .round))
        XCTAssertEqual(state.anchor, p("d2"))
    }
}

final class TurnFlowTests: XCTestCase {
    func testLegalActionsIncludeMovesAndPushes() throws {
        let state = try GameStateFixtures.standardOpening()
        let actions = state.legalActions()
        XCTAssertTrue(actions.contains(.push(from: p("d2"), .right)))
        XCTAssertTrue(actions.contains { if case .move = $0 { true } else { false } })
        // No actions for player two's pieces.
        XCTAssertFalse(actions.contains { if case .move(let from, _) = $0 { from == p("f2") } else { false } })
    }

    func testSerializationRoundTrip() throws {
        var state = try GameStateFixtures.standardOpening()
        try state.apply(.move(from: p("c2"), to: p("c1")))
        try state.apply(.push(from: p("d2"), .right))
        let data = try state.serialized()
        let decoded = try GameState(serialized: data)
        XCTAssertEqual(decoded, state)
    }
}

/// Builders for test positions.
enum GameStateFixtures {
    /// A symmetric opening with squares stacked on the centre line:
    /// ```
    ///       abcdefgh
    ///     4   .....    4
    ///     3 ..○■□●.. 3      ■ = P1 square  ○ = P1 round
    ///     2 ..○■□●.. 2      □ = P2 square  ● = P2 round
    ///     1  ..■□.    1
    ///       abcdefgh
    /// ```
    static func standardOpening() throws -> GameState {
        var state = GameState()
        try place(&state, one: [
            ("square", "d2"), ("square", "d3"), ("square", "d1"), ("round", "c2"), ("round", "c3"),
        ], two: [
            ("square", "e2"), ("square", "e3"), ("square", "e1"), ("round", "f2"), ("round", "f3"),
        ])
        return state
    }

    static func place(
        _ state: inout GameState,
        one: [(String, String)],
        two: [(String, String)]
    ) throws {
        for (kind, notation) in one {
            try state.apply(.place(PieceKind(rawValue: kind)!, at: Position(notation)!))
        }
        for (kind, notation) in two {
            try state.apply(.place(PieceKind(rawValue: kind)!, at: Position(notation)!))
        }
    }
}
