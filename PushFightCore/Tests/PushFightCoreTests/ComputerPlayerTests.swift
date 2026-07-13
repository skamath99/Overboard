import XCTest
@testable import PushFightCore

final class ComputerPlayerTests: XCTestCase {
    // MARK: - Placement

    func testPlacementIsLegalForBothPlayers() throws {
        for level in AILevel.allCases {
            var record = GameRecord()
            let ai = ComputerPlayer(level: level)
            for seed: UInt64 in [1, 2] {
                let actions = ai.turnActions(for: record.state, seed: seed)
                XCTAssertEqual(actions.count, GameState.piecesPerPlayer, "level \(level) should place all pieces")
                for action in actions {
                    XCTAssertNoThrow(try record.apply(action))
                }
            }
            XCTAssertEqual(record.state.phase, .playing, "both sides placed, game should start")
        }
    }

    // MARK: - Tactics

    /// Player one to move; pushing right from d1 drops the round on f1 off
    /// the board (d1–e1–f1, then g1 is missing → open edge).
    private func winInOnePosition() throws -> GameState {
        var record = GameRecord()
        for action in Self.placements(
            one: [(.square, "d1"), (.square, "d2"), (.square, "d3"), (.round, "c2"), (.round, "c3")],
            two: [(.round, "e1"), (.round, "f1"), (.square, "f2"), (.square, "f3"), (.square, "e3")]
        ) {
            try record.apply(action)
        }
        return record.state
    }

    func testEveryLevelTakesWinInOne() throws {
        let state = try winInOnePosition()
        for level in AILevel.allCases {
            for seed: UInt64 in 0..<3 {
                var game = state
                let actions = ComputerPlayer(level: level).turnActions(for: game, seed: seed)
                XCTAssertFalse(actions.isEmpty)
                for action in actions {
                    XCTAssertNoThrow(try game.apply(action))
                }
                XCTAssertEqual(game.phase, .finished(winner: .one), "level \(level), seed \(seed) should win on the spot")
            }
        }
    }

    /// Player two to move while player one threatens win-in-1 (d1 push right
    /// would drop f1 off). Levels that look a full turn ahead must defend.
    private func lossInOnePosition() throws -> GameState {
        var record = GameRecord()
        for action in Self.placements(
            one: [(.square, "d1"), (.square, "d3"), (.square, "b2"), (.round, "c2"), (.round, "d4")],
            two: [(.round, "e1"), (.round, "f1"), (.square, "f2"), (.square, "f3"), (.square, "g3")]
        ) {
            try record.apply(action)
        }
        // Harmless push that keeps the d1 threat: b2 pushes c2 to d2.
        try record.apply(.push(from: Position("b2")!, .right))
        XCTAssertEqual(record.state.currentPlayer, .two)
        // Verify the premise: d1 pushing right drops player two's f1 round off.
        let (line, fallsOff) = try record.state.pushLine(from: Position("d1")!, .right)
        XCTAssertTrue(fallsOff)
        XCTAssertEqual(record.state.piece(at: line.last!)?.owner, .two)
        return record.state
    }

    func testSearchingLevelsAvoidLossInOne() throws {
        let state = try lossInOnePosition()
        for level in [AILevel.firstMate, .captain] {
            for seed: UInt64 in 0..<3 {
                var game = state
                let actions = ComputerPlayer(level: level).turnActions(for: game, seed: seed)
                for action in actions {
                    XCTAssertNoThrow(try game.apply(action))
                }
                if game.phase == .playing {
                    XCTAssertFalse(
                        Self.hasWinningTurn(game),
                        "level \(level), seed \(seed) left a win-in-1 on the board"
                    )
                } else {
                    XCTAssertEqual(game.phase, .finished(winner: .two), "ending the game is only fine by winning")
                }
            }
        }
    }

    // MARK: - Full games

    func testComputerVersusComputerPlaysLegally() throws {
        var finishes = 0
        for (seedBase, levels) in [(10, (AILevel.bosun, AILevel.deckhand)), (20, (.firstMate, .bosun))] {
            var record = GameRecord()
            var turns = 0
            while record.winner == nil && turns < 120 {
                let mover = ComputerPlayer(
                    level: record.state.currentPlayer == .one ? levels.0 : levels.1
                )
                let actions = mover.turnActions(for: record.state, seed: UInt64(seedBase + turns))
                XCTAssertFalse(actions.isEmpty, "AI returned no actions in a live game")
                for action in actions where record.winner == nil {
                    XCTAssertNoThrow(try record.apply(action), "illegal AI action \(action) at turn \(turns)")
                }
                turns += 1
            }
            if record.winner != nil { finishes += 1 }
        }
        XCTAssertGreaterThan(finishes, 0, "at least one AI-vs-AI game should reach a result")
    }

    func testCaptainDecidesWithinBudget() throws {
        var record = GameRecord()
        let ai = ComputerPlayer(level: .captain)
        for seed: UInt64 in [1, 2] {
            for action in ai.turnActions(for: record.state, seed: seed) {
                try record.apply(action)
            }
        }
        let start = Date()
        let actions = ai.turnActions(for: record.state, seed: 7)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(actions.isEmpty)
        XCTAssertLessThan(elapsed, 8, "captain took \(elapsed)s for one turn")
    }

    // MARK: - Helpers

    private static func placements(
        one: [(PieceKind, String)], two: [(PieceKind, String)]
    ) -> [Action] {
        (one + two).map { .place($0.0, at: Position($0.1)!) }
    }

    /// Brute force: does the current player have any complete turn that wins
    /// immediately? Explores every distinct piece configuration after ≤2 moves.
    static func hasWinningTurn(_ state: GameState) -> Bool {
        guard case .playing = state.phase else { return false }
        let player = state.currentPlayer
        var configs: [GameState] = [state]
        var seen: Set<GameState> = [state]
        var frontier = configs
        for _ in 0..<state.movesRemaining {
            var next: [GameState] = []
            for config in frontier {
                for action in config.legalActions() {
                    guard case .move = action, let moved = try? config.applying(action) else { continue }
                    guard case .playing = moved.phase else { continue }
                    if seen.insert(moved).inserted {
                        configs.append(moved)
                        next.append(moved)
                    }
                }
            }
            frontier = next
        }
        for config in configs {
            for action in config.legalActions() {
                guard case .push = action, let pushed = try? config.applying(action) else { continue }
                if pushed.phase == .finished(winner: player) { return true }
            }
        }
        return false
    }
}
