/// A single player input, validated and applied by ``GameState/apply(_:)``.
public enum Action: Hashable, Codable, Sendable {
    /// Setup phase: place one of your unplaced pieces on your half of the board.
    case place(PieceKind, at: Position)
    /// Slide one of your pieces to an empty tile reachable through empty tiles.
    case move(from: Position, to: Position)
    /// Push with one of your square pieces. Mandatory to end a turn.
    case push(from: Position, Direction)
}

public enum GameError: Error, Equatable, Sendable {
    case gameIsOver
    case wrongPhase
    case notYourTurn
    case notATile
    case tileOccupied
    case outsideHomeArea
    case noPieceOfThatKindLeft
    case noPieceThere
    case notYourPiece
    case noMovesRemaining
    case destinationUnreachable
    case onlySquaresCanPush
    case nothingToPush
    case pushBlockedByRail
    case pushBlockedByAnchor
}
