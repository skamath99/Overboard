import XCTest
@testable import PushFightCore

/// Timing diagnostics for the AI search (not assertions of strength).
/// Run with `swift test --filter Benchmarks` and read the printed numbers.
final class ComputerPlayerBenchmarks: XCTestCase {
    func testTimingsAcrossGamePhases() throws {
        let opener = ComputerPlayer(level: .firstMate)
        var record = GameRecord()
        outer: for base: UInt64 in stride(from: 0, to: 10_000, by: 1000) {
            record = GameRecord()
            for seed in [base + 11, base + 12] {
                for action in opener.turnActions(for: record.state, seed: seed) {
                    try record.apply(action)
                }
            }
            for turn in 0..<6 {
                guard record.winner == nil else { continue outer }
                for action in opener.turnActions(for: record.state, seed: base + UInt64(100 + turn)) where record.winner == nil {
                    try record.apply(action)
                }
            }
            if record.winner == nil { break }
        }
        guard record.winner == nil else {
            print("BENCH: no surviving mid-game found")
            return
        }
        print("BENCH position after \(record.actions.count) actions")

        for level in [AILevel.bosun, .firstMate, .captain] {
            let start = Date()
            _ = ComputerPlayer(level: level).turnActions(for: record.state, seed: 5)
            print(String(format: "BENCH %@ turn: %.3fs", "\(level)", Date().timeIntervalSince(start)))
        }
    }

    /// Strength probe: the captain should beat the weak levels. Slow (several
    /// minutes), so it only runs when STRENGTH=1 is set in the environment.
    func testCaptainBeatsWeakLevels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRENGTH"] == "1")
        var captainWins = 0, games = 0
        for (opponent, base) in [(AILevel.deckhand, 1000), (.deckhand, 2000), (.bosun, 3000), (.bosun, 4000)] {
            // Captain alternates sides across the pairings.
            let captainSide: Player = games % 2 == 0 ? .one : .two
            var record = GameRecord()
            var turn = 0
            while record.winner == nil && turn < 80 {
                let mover = record.state.placingPlayer ?? record.state.currentPlayer
                let level = mover == captainSide ? AILevel.captain : opponent
                let actions = ComputerPlayer(level: level)
                    .turnActions(for: record.state, seed: UInt64(base + turn))
                for action in actions where record.winner == nil {
                    try record.apply(action)
                }
                turn += 1
            }
            games += 1
            let outcome = record.winner.map { $0 == captainSide ? "captain win" : "captain LOSS" } ?? "draw (80 turns)"
            print("STRENGTH game \(games) vs \(opponent): \(outcome) in \(turn) turns")
            if record.winner == captainSide { captainWins += 1 }
        }
        print("STRENGTH captain wins \(captainWins)/\(games)")
        XCTAssertGreaterThanOrEqual(captainWins, 3, "captain should dominate weak levels")
    }
}
