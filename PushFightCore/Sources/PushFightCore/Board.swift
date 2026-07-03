/// What lies one step from a tile in a given direction.
public enum BoardEdge: Equatable, Sendable {
    /// Another playable tile.
    case tile(Position)
    /// A side rail: pieces can never be pushed past it.
    case rail
    /// Open edge: a piece pushed here falls off the board.
    case off
}

/// Static geometry of the Push Fight board.
///
/// The board is a 4×8 grid with six squares missing (a1, g1, h1, a4, b4, h4),
/// leaving 26 playable tiles:
/// ```
///       abcdefgh
///     4   ▢▢▢▢▢    4    ▔ rail above row 4
///     3 ▢▢▢▢▢▢▢▢ 3
///     2 ▢▢▢▢▢▢▢▢ 2
///     1  ▢▢▢▢▢    1    ▁ rail below row 1
///       abcdefgh
/// ```
/// Rails run along the top edge of row 4 and the bottom edge of row 1, so
/// pieces cannot be pushed off vertically there. Every other off-board edge is
/// open: the left and right ends, and the gaps left by missing corner squares
/// (e.g. pushing up from b3 or down from g2 pushes a piece off).
public enum Board {
    public static let columnCount = 8
    public static let rowCount = 4

    private static let missingSquares: Set<Position> = Set(
        ["a1", "g1", "h1", "a4", "b4", "h4"].compactMap(Position.init)
    )

    public static let allTiles: [Position] = (0..<columnCount).flatMap { column in
        (0..<rowCount).compactMap { row in
            let position = Position(column: column, row: row)
            return isTile(position) ? position : nil
        }
    }

    public static func isTile(_ position: Position) -> Bool {
        (0..<columnCount).contains(position.column)
            && (0..<rowCount).contains(position.row)
            && !missingSquares.contains(position)
    }

    public static func edge(from position: Position, _ direction: Direction) -> BoardEdge {
        let next = position.shifted(direction)
        if isTile(next) {
            return .tile(next)
        }
        if direction == .up, position.row == rowCount - 1 {
            return .rail
        }
        if direction == .down, position.row == 0 {
            return .rail
        }
        return .off
    }

    /// The columns a player may place pieces in during setup.
    public static func homeColumns(for player: Player) -> ClosedRange<Int> {
        player == .one ? 0...3 : 4...7
    }
}
