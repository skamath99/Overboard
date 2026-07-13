import Foundation

/// Difficulty of the built-in computer opponent.
///
/// The level design follows the depth-limited imperfect play described in
/// Maks Verver's Push Fight solver project (github.com/maksverver/pushfight,
/// AI.txt): every level takes a win it can see, lower levels look shallower
/// and pick randomly among near-equal moves — so they make human-like
/// mistakes — and higher levels search deeper turn trees. The solver's exact
/// database (hundreds of GB) cannot ship in an app, so deeper values come
/// from a heuristic search instead of perfect lookups.
public enum AILevel: Int, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case deckhand = 1
    case bosun = 2
    case firstMate = 3
    case captain = 4

    public var id: Int { rawValue }

    public static func < (lhs: AILevel, rhs: AILevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Chooses complete turns (placement, or moves + push) for one side.
/// Stateless and Sendable: call `turnActions(for:)` off the main thread and
/// apply the returned actions through the normal engine validation.
public struct ComputerPlayer: Sendable {
    public let level: AILevel

    public init(level: AILevel) {
        self.level = level
    }

    /// The full action sequence the computer wants to play from `state`:
    /// all five placements during setup, or up to two moves plus a push.
    /// Returns a single fallback action when no complete turn exists (the
    /// position is lost; the engine will finish the game).
    public func turnActions(for state: GameState) -> [Action] {
        var rng = SplitMix64(seed: UInt64.random(in: .min ... .max))
        return turnActions(for: state, rng: &rng)
    }

    /// Deterministic variant for tests.
    public func turnActions(for state: GameState, seed: UInt64) -> [Action] {
        var rng = SplitMix64(seed: seed)
        return turnActions(for: state, rng: &rng)
    }

    private func turnActions(for state: GameState, rng: inout SplitMix64) -> [Action] {
        switch state.phase {
        case .finished:
            return []
        case .placement:
            return placementActions(for: state, rng: &rng)
        case .playing:
            if let plan = choosePlan(for: state, rng: &rng) {
                return Self.actions(for: plan)
            }
            // No turn ends in a push, so this position is already lost.
            // Play any legal action and let the engine finish the game.
            if let action = state.legalActions().first { return [action] }
            return []
        }
    }

    // MARK: - Placement

    /// Solid opening setups for player one (columns a–d): a square wall near
    /// the centre line with the rounds sheltered behind it. Player two gets
    /// the same setups rotated 180°, the board's only symmetry.
    private static let openingSetups: [[(PieceKind, String)]] = [
        [(.square, "d1"), (.square, "d2"), (.square, "d3"), (.round, "c2"), (.round, "c3")],
        [(.square, "d2"), (.square, "d3"), (.square, "c4"), (.round, "c2"), (.round, "c3")],
        [(.square, "c2"), (.square, "d3"), (.square, "d1"), (.round, "d2"), (.round, "c3")],
    ]

    private func placementActions(for state: GameState, rng: inout SplitMix64) -> [Action] {
        guard let placer = state.placingPlayer else { return [] }
        let setup = Self.openingSetups.randomElement(using: &rng)!
        var actions: [Action] = []
        var working = state
        for (kind, notation) in setup {
            guard var position = Position(notation) else { continue }
            if placer == .two {
                position = Position(column: 7 - position.column, row: 3 - position.row)
            }
            let action = Action.place(kind, at: position)
            guard let next = try? working.applying(action) else { continue }
            working = next
            actions.append(action)
        }
        // Fallback for unusual mid-placement states the setup didn't cover.
        while working.placingPlayer == placer, let action = working.legalActions().first {
            guard let next = try? working.applying(action) else { break }
            working = next
            actions.append(action)
        }
        return actions
    }

    // MARK: - Turn selection

    private struct Params {
        let depth: Int
        let rootBeam: Int
        let innerBeam: Int
        /// Moves scoring within `epsilon` of the best are considered equal
        /// and picked from at random, so weaker levels vary their play.
        let epsilon: Double
        let budget: TimeInterval
    }

    private var params: Params {
        switch level {
        case .deckhand: Params(depth: 0, rootBeam: 0, innerBeam: 0, epsilon: 0, budget: 0.5)
        case .bosun: Params(depth: 1, rootBeam: .max, innerBeam: 0, epsilon: 25, budget: 1.5)
        case .firstMate: Params(depth: 2, rootBeam: 64, innerBeam: 0, epsilon: 8, budget: 3)
        case .captain: Params(depth: 3, rootBeam: 20, innerBeam: 10, epsilon: 0.5, budget: 5)
        }
    }

    private static let winValue = 1_000_000.0

    private func choosePlan(for state: GameState, rng: inout SplitMix64) -> TurnPlan? {
        let board = Self.bitboard(from: state)
        let side = state.currentPlayer
        let plans = Self.turns(from: board, side: side, maxMoves: state.movesRemaining)
        guard !plans.isEmpty else { return nil }

        // Every level takes an immediate win when one exists.
        let wins = plans.filter { plan in
            plan.winner == side || (plan.winner == nil && Self.isStuck(plan.result, side: side.opponent))
        }
        if !wins.isEmpty { return wins.randomElement(using: &rng) }

        if level == .deckhand {
            // Random play, avoiding only the outright suicidal turns.
            let safe = plans.filter { $0.winner == nil }
            return (safe.isEmpty ? plans : safe).randomElement(using: &rng)
        }

        let params = params
        var scored: [(score: Double, plan: TurnPlan)] = plans.map { plan in
            if plan.winner != nil {
                // Only losing terminals remain (wins were taken above).
                return (-Self.winValue, plan)
            }
            return (Self.evaluate(plan.result, for: side), plan)
        }
        scored.sort { $0.score > $1.score }

        guard params.depth >= 2 else {
            return pick(from: scored, epsilon: params.epsilon, rng: &rng)
        }

        // Deepen the statically best candidates; the rest stay out of the
        // running so an unexamined move can't win on its inflated static score.
        let deadline = Date().addingTimeInterval(params.budget)
        var deepened: [(score: Double, plan: TurnPlan)] = []
        for (score, plan) in scored.prefix(params.rootBeam) {
            let value: Double
            if score <= -Self.winValue {
                value = score
            } else {
                value = -negamax(
                    plan.result, toMove: side.opponent, depth: params.depth - 1, ply: 1,
                    alpha: -Double.infinity, beta: Double.infinity,
                    innerBeam: params.innerBeam, deadline: deadline
                )
            }
            deepened.append((value, plan))
            if value >= Self.winValue - 100 { break }
            if Date() > deadline, deepened.count >= 4 { break }
        }
        deepened.sort { $0.score > $1.score }
        return pick(from: deepened, epsilon: params.epsilon, rng: &rng)
    }

    private func pick(
        from sorted: [(score: Double, plan: TurnPlan)],
        epsilon: Double,
        rng: inout SplitMix64
    ) -> TurnPlan? {
        guard let best = sorted.first else { return nil }
        let candidates = sorted.prefix { $0.score >= best.score - epsilon }
        return candidates.randomElement(using: &rng)?.plan
    }

    /// Value of `board` for `toMove`, looking `depth` turns ahead. Successor
    /// turns are ordered by static evaluation and only the best `innerBeam`
    /// are expanded further.
    private func negamax(
        _ board: Bitboard, toMove: Player, depth: Int, ply: Int,
        alpha: Double, beta: Double, innerBeam: Int, deadline: Date
    ) -> Double {
        let plans = Self.turns(from: board, side: toMove, maxMoves: 2)
        // No complete turn means the mover cannot end a turn with a push:
        // a loss, however the remaining moves are spent.
        if plans.isEmpty { return -(Self.winValue - Double(ply)) }

        var scored: [(score: Double, result: Bitboard, terminal: Bool)] = plans.map { plan in
            if let winner = plan.winner {
                let value = Self.winValue - Double(ply + 1)
                return (winner == toMove ? value : -value, plan.result, true)
            }
            if Self.isStuck(plan.result, side: toMove.opponent) {
                return (Self.winValue - Double(ply + 1), plan.result, true)
            }
            return (Self.evaluate(plan.result, for: toMove), plan.result, false)
        }
        scored.sort { $0.score > $1.score }

        if depth <= 1 { return scored[0].score }

        var best = -Double.infinity
        var alpha = alpha
        for (score, result, terminal) in scored.prefix(max(innerBeam, 1)) {
            let value = terminal
                ? score
                : -negamax(
                    result, toMove: toMove.opponent, depth: depth - 1, ply: ply + 1,
                    alpha: -beta, beta: -alpha, innerBeam: innerBeam, deadline: deadline
                )
            best = max(best, value)
            alpha = max(alpha, best)
            if alpha >= beta || Date() > deadline { break }
        }
        return best
    }

    // MARK: - Static evaluation

    /// Heuristic value of a position for `side`. Small numbers by design:
    /// centralised pieces are good, pieces beside an open edge are in danger,
    /// and having pushes available matters (a player who cannot push loses).
    private static func evaluate(_ board: Bitboard, for side: Player) -> Double {
        materialScore(board, side: side) - materialScore(board, side: side.opponent)
    }

    private static func materialScore(_ board: Bitboard, side: Player) -> Double {
        var score = 0.0
        var bits = board.mask(of: side)
        while bits != 0 {
            let tile = bits.trailingZeroBitCount
            bits &= bits - 1
            score += Geometry.tileValue[tile]
            score -= 14 * Double(Geometry.openEdgeCount[tile])
        }
        score += 2.5 * Double(pushCount(board, side: side))
        return score
    }

    private static func pushCount(_ board: Bitboard, side: Player) -> Int {
        var count = 0
        var squares = board.mask(of: side) & board.squares
        while squares != 0 {
            let tile = squares.trailingZeroBitCount
            squares &= squares - 1
            for direction in 0..<4 where push(board, from: tile, direction: direction) != nil {
                count += 1
            }
        }
        return count
    }

    /// True when `side` has no legal action at all: no piece can move and no
    /// square can push — the engine's immediate loss condition.
    private static func isStuck(_ board: Bitboard, side: Player) -> Bool {
        let occupied = board.occupied
        var bits = board.mask(of: side)
        while bits != 0 {
            let tile = bits.trailingZeroBitCount
            bits &= bits - 1
            for neighbor in Geometry.adjacentTiles[tile] where occupied & (1 << neighbor) == 0 {
                return false
            }
        }
        return pushCount(board, side: side) == 0
    }

    // MARK: - Turn enumeration

    private struct TurnPlan {
        var moves: [(from: Int, to: Int)]
        var pushFrom: Int
        var pushDirection: Int
        var result: Bitboard
        /// Set when the push ended the game by dropping a piece off the board.
        var winner: Player?
    }

    /// All distinct complete turns (0–`maxMoves` moves followed by a push),
    /// deduplicated by resulting position.
    private static func turns(from board: Bitboard, side: Player, maxMoves: Int) -> [TurnPlan] {
        struct ConfigKey: Hashable {
            let one: UInt32, two: UInt32, squares: UInt32
        }

        var configs: [(Bitboard, [(from: Int, to: Int)])] = [(board, [])]
        var seen: Set<ConfigKey> = [ConfigKey(one: board.one, two: board.two, squares: board.squares)]
        var frontier = configs

        for _ in 0..<max(0, maxMoves) {
            var next: [(Bitboard, [(from: Int, to: Int)])] = []
            for (config, path) in frontier {
                let occupied = config.occupied
                var bits = config.mask(of: side)
                while bits != 0 {
                    let from = bits.trailingZeroBitCount
                    bits &= bits - 1
                    var reach = reachable(occupied: occupied, from: from)
                    while reach != 0 {
                        let to = reach.trailingZeroBitCount
                        reach &= reach - 1
                        var moved = config
                        moved.movePiece(from: from, to: to, side: side)
                        let key = ConfigKey(one: moved.one, two: moved.two, squares: moved.squares)
                        guard seen.insert(key).inserted else { continue }
                        let extended = path + [(from, to)]
                        configs.append((moved, extended))
                        next.append((moved, extended))
                    }
                }
            }
            frontier = next
        }

        struct ResultKey: Hashable {
            let one: UInt32, two: UInt32, squares: UInt32
            let anchor: Int, winner: Player?
        }

        var plans: [TurnPlan] = []
        var seenResults = Set<ResultKey>()
        for (config, path) in configs {
            var squares = config.mask(of: side) & config.squares
            while squares != 0 {
                let from = squares.trailingZeroBitCount
                squares &= squares - 1
                for direction in 0..<4 {
                    guard let (result, winner) = push(config, from: from, direction: direction) else { continue }
                    let key = ResultKey(
                        one: result.one, two: result.two, squares: result.squares,
                        anchor: result.anchor, winner: winner
                    )
                    guard seenResults.insert(key).inserted else { continue }
                    plans.append(TurnPlan(
                        moves: path, pushFrom: from, pushDirection: direction,
                        result: result, winner: winner
                    ))
                }
            }
        }
        return plans
    }

    /// Empty tiles reachable from `from` through empty tiles (flood fill;
    /// mirrors `GameState.reachableTiles`).
    private static func reachable(occupied: UInt32, from: Int) -> UInt32 {
        var result: UInt32 = 0
        var stack: [Int] = [from]
        while let current = stack.popLast() {
            for neighbor in Geometry.adjacentTiles[current] {
                let bit: UInt32 = 1 << neighbor
                if occupied & bit == 0 && result & bit == 0 {
                    result |= bit
                    stack.append(neighbor)
                }
            }
        }
        return result
    }

    /// Applies a push, mirroring `GameState.applyPush`: the whole contiguous
    /// line shifts one tile; invalid if blocked by a rail or the anchor.
    /// Returns nil for illegal pushes; `winner` is set when a piece fell off.
    private static func push(_ board: Bitboard, from: Int, direction: Int) -> (Bitboard, Player?)? {
        var line = [from]
        var cursor = from
        while true {
            let next = Geometry.neighbor[cursor][direction]
            if next == Geometry.rail { return nil }
            if next == Geometry.off {
                guard line.count > 1 else { return nil }
                break
            }
            if board.occupied & (1 << next) == 0 {
                guard line.count > 1 else { return nil }
                break
            }
            if next == board.anchor { return nil }
            line.append(next)
            cursor = next
        }

        var result = board
        var winner: Player?
        for tile in line.reversed() {
            let bit: UInt32 = 1 << tile
            let ownedByOne = result.one & bit != 0
            let isSquare = result.squares & bit != 0
            result.one &= ~bit
            result.two &= ~bit
            result.squares &= ~bit
            let next = Geometry.neighbor[tile][direction]
            if next >= 0 {
                let nextBit: UInt32 = 1 << next
                if ownedByOne { result.one |= nextBit } else { result.two |= nextBit }
                if isSquare { result.squares |= nextBit }
            } else {
                // The piece fell off; its owner loses.
                winner = ownedByOne ? .two : .one
            }
        }
        result.anchor = Geometry.neighbor[from][direction]
        return (result, winner)
    }

    // MARK: - Board representation

    /// Positions as bit masks over the 26 playable tiles, for fast search.
    private struct Bitboard: Hashable {
        var one: UInt32
        var two: UInt32
        /// Union of both players' square pieces.
        var squares: UInt32
        /// Tile index of the anchored piece, or -1.
        var anchor: Int

        var occupied: UInt32 { one | two }

        func mask(of player: Player) -> UInt32 {
            player == .one ? one : two
        }

        mutating func movePiece(from: Int, to: Int, side: Player) {
            let fromBit: UInt32 = 1 << from
            let toBit: UInt32 = 1 << to
            if side == .one { one = (one & ~fromBit) | toBit } else { two = (two & ~fromBit) | toBit }
            if squares & fromBit != 0 { squares = (squares & ~fromBit) | toBit }
        }
    }

    private static func bitboard(from state: GameState) -> Bitboard {
        var board = Bitboard(one: 0, two: 0, squares: 0, anchor: -1)
        for (position, piece) in state.pieces {
            guard let index = Geometry.index[position] else { continue }
            let bit: UInt32 = 1 << index
            if piece.owner == .one { board.one |= bit } else { board.two |= bit }
            if piece.kind == .square { board.squares |= bit }
        }
        if let anchor = state.anchor, let index = Geometry.index[anchor] {
            board.anchor = index
        }
        return board
    }

    private static func actions(for plan: TurnPlan) -> [Action] {
        var actions: [Action] = plan.moves.map {
            .move(from: Geometry.positions[$0.from], to: Geometry.positions[$0.to])
        }
        actions.append(.push(from: Geometry.positions[plan.pushFrom], Geometry.directions[plan.pushDirection]))
        return actions
    }

    /// Precomputed board geometry shared by all searches.
    private enum Geometry {
        static let rail = -1
        static let off = -2

        static let positions: [Position] = Board.allTiles
        static let directions: [Direction] = Direction.allCases
        static let index: [Position: Int] = Dictionary(
            uniqueKeysWithValues: positions.enumerated().map { ($0.element, $0.offset) }
        )

        /// neighbor[tile][direction] → tile index, `rail`, or `off`.
        static let neighbor: [[Int]] = positions.map { position in
            directions.map { direction in
                switch Board.edge(from: position, direction) {
                case .tile(let next): index[next]!
                case .rail: rail
                case .off: off
                }
            }
        }

        static let adjacentTiles: [[Int]] = neighbor.map { $0.filter { $0 >= 0 } }

        /// How many directions push a piece on this tile straight off the board.
        static let openEdgeCount: [Int] = neighbor.map { $0.filter { $0 == off }.count }

        /// Centralisation bonus: the middle columns and rows are strongest.
        static let tileValue: [Double] = positions.map { position in
            let columnWeight: [Double] = [0, 3, 6, 9, 9, 6, 3, 0]
            let rowWeight: [Double] = [0, 3, 3, 0]
            return columnWeight[position.column] + rowWeight[position.row]
        }
    }
}

/// Small deterministic RNG so tests can seed the computer player.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
