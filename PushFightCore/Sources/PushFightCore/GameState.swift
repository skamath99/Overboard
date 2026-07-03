import Foundation

/// The complete state of a Push Fight game. A value type: `apply(_:)` mutates
/// a copy-on-write struct, so snapshots and undo are free.
public struct GameState: Hashable, Codable, Sendable {
    public enum Phase: Hashable, Codable, Sendable {
        /// Players are placing their pieces. Player one places all five first.
        case placement
        case playing
        case finished(winner: Player)
    }

    public static let squaresPerPlayer = 3
    public static let roundsPerPlayer = 2
    public static let piecesPerPlayer = squaresPerPlayer + roundsPerPlayer
    public static let movesPerTurn = 2

    public private(set) var pieces: [Position: Piece]
    /// The piece that made the last push. It cannot be pushed this turn.
    public private(set) var anchor: Position?
    public private(set) var currentPlayer: Player
    public private(set) var movesUsed: Int
    public private(set) var phase: Phase

    public init() {
        pieces = [:]
        anchor = nil
        currentPlayer = .one
        movesUsed = 0
        phase = .placement
    }

    // MARK: - Queries

    public func piece(at position: Position) -> Piece? {
        pieces[position]
    }

    public var movesRemaining: Int {
        Self.movesPerTurn - movesUsed
    }

    /// During placement, the player who places next; nil once the game started.
    public var placingPlayer: Player? {
        guard phase == .placement else { return nil }
        return placedCount(for: .one) < Self.piecesPerPlayer ? .one : .two
    }

    public func placedCount(for player: Player, kind: PieceKind? = nil) -> Int {
        pieces.values.filter { $0.owner == player && (kind == nil || $0.kind == kind) }.count
    }

    /// Empty tiles a piece at `position` can slide to (breadth-first search
    /// through empty tiles). Does not include the starting tile.
    public func reachableTiles(from position: Position) -> Set<Position> {
        var reachable: Set<Position> = []
        var frontier: [Position] = [position]
        while let current = frontier.popLast() {
            for direction in Direction.allCases {
                guard case .tile(let next) = Board.edge(from: current, direction),
                      pieces[next] == nil,
                      !reachable.contains(next)
                else { continue }
                reachable.insert(next)
                frontier.append(next)
            }
        }
        return reachable
    }

    /// The line of occupied positions a push from `position` would shift,
    /// starting with the pusher itself, or a thrown error explaining why the
    /// push is illegal. `fallsOff` is true when the last piece in the line
    /// would leave the board.
    public func pushLine(from position: Position, _ direction: Direction) throws -> (line: [Position], fallsOff: Bool) {
        guard let pusher = pieces[position] else { throw GameError.noPieceThere }
        guard pusher.kind == .square else { throw GameError.onlySquaresCanPush }

        var line = [position]
        var cursor = position
        while true {
            switch Board.edge(from: cursor, direction) {
            case .tile(let next):
                guard pieces[next] != nil else {
                    guard line.count > 1 else { throw GameError.nothingToPush }
                    return (line, false)
                }
                guard next != anchor else { throw GameError.pushBlockedByAnchor }
                line.append(next)
                cursor = next
            case .rail:
                throw GameError.pushBlockedByRail
            case .off:
                guard line.count > 1 else { throw GameError.nothingToPush }
                return (line, true)
            }
        }
    }

    public func canPush(from position: Position, _ direction: Direction) -> Bool {
        (try? pushLine(from: position, direction)) != nil
    }

    /// All actions the current player may take right now.
    public func legalActions() -> [Action] {
        switch phase {
        case .finished:
            return []
        case .placement:
            guard let player = placingPlayer else { return [] }
            let availableKinds = PieceKind.allCases.filter { kind in
                placedCount(for: player, kind: kind) < maxCount(of: kind)
            }
            return Board.allTiles.flatMap { tile -> [Action] in
                guard Board.homeColumns(for: player).contains(tile.column), pieces[tile] == nil else { return [] }
                return availableKinds.map { .place($0, at: tile) }
            }
        case .playing:
            var actions: [Action] = []
            for (position, piece) in pieces where piece.owner == currentPlayer {
                if movesUsed < Self.movesPerTurn {
                    actions += reachableTiles(from: position).map { .move(from: position, to: $0) }
                }
                if piece.kind == .square {
                    actions += Direction.allCases
                        .filter { canPush(from: position, $0) }
                        .map { .push(from: position, $0) }
                }
            }
            return actions
        }
    }

    // MARK: - Applying actions

    public mutating func apply(_ action: Action) throws {
        switch action {
        case .place(let kind, let position):
            try applyPlace(kind, at: position)
        case .move(let from, let to):
            try applyMove(from: from, to: to)
        case .push(let from, let direction):
            try applyPush(from: from, direction)
        }
    }

    /// A convenience that returns the resulting state instead of mutating.
    public func applying(_ action: Action) throws -> GameState {
        var next = self
        try next.apply(action)
        return next
    }

    private func maxCount(of kind: PieceKind) -> Int {
        kind == .square ? Self.squaresPerPlayer : Self.roundsPerPlayer
    }

    private mutating func applyPlace(_ kind: PieceKind, at position: Position) throws {
        guard case .placement = phase, let player = placingPlayer else { throw GameError.wrongPhase }
        guard Board.isTile(position) else { throw GameError.notATile }
        guard Board.homeColumns(for: player).contains(position.column) else { throw GameError.outsideHomeArea }
        guard pieces[position] == nil else { throw GameError.tileOccupied }
        guard placedCount(for: player, kind: kind) < maxCount(of: kind) else { throw GameError.noPieceOfThatKindLeft }

        pieces[position] = Piece(owner: player, kind: kind)

        if placedCount(for: .two) == Self.piecesPerPlayer {
            phase = .playing
            currentPlayer = .one
            movesUsed = 0
        }
    }

    private mutating func applyMove(from: Position, to: Position) throws {
        guard case .playing = phase else { throw phaseError }
        guard let piece = pieces[from] else { throw GameError.noPieceThere }
        guard piece.owner == currentPlayer else { throw GameError.notYourPiece }
        guard movesUsed < Self.movesPerTurn else { throw GameError.noMovesRemaining }
        guard Board.isTile(to), pieces[to] == nil, reachableTiles(from: from).contains(to) else {
            throw GameError.destinationUnreachable
        }

        pieces[to] = pieces.removeValue(forKey: from)
        movesUsed += 1
        finishIfCurrentPlayerIsStuck()
    }

    private mutating func applyPush(from: Position, _ direction: Direction) throws {
        guard case .playing = phase else { throw phaseError }
        guard let piece = pieces[from] else { throw GameError.noPieceThere }
        guard piece.owner == currentPlayer else { throw GameError.notYourPiece }

        let (line, _) = try pushLine(from: from, direction)

        var fallenPiece: Piece?
        for position in line.reversed() {
            let moved = pieces.removeValue(forKey: position)!
            if case .tile(let destination) = Board.edge(from: position, direction) {
                pieces[destination] = moved
            } else {
                fallenPiece = moved
            }
        }

        anchor = from.shifted(direction)

        if let fallenPiece {
            phase = .finished(winner: fallenPiece.owner.opponent)
            return
        }

        currentPlayer = currentPlayer.opponent
        movesUsed = 0
        finishIfCurrentPlayerIsStuck()
    }

    /// Push Fight's second loss condition: a player who cannot end their turn
    /// with a push loses. Once no legal action remains (no moves left and no
    /// push available, or no actions at all), the game is over.
    private mutating func finishIfCurrentPlayerIsStuck() {
        if legalActions().isEmpty {
            phase = .finished(winner: currentPlayer.opponent)
        }
    }

    private var phaseError: GameError {
        if case .finished = phase { return .gameIsOver }
        return .wrongPhase
    }

    // MARK: - Serialization (e.g. for GKTurnBasedMatch.matchData)

    public func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(serialized data: Data) throws {
        self = try JSONDecoder().decode(GameState.self, from: data)
    }
}
