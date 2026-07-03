/// A coordinate on the board grid. Columns run a–h (0–7), rows run 1–4 (0–3, bottom to top).
public struct Position: Hashable, Codable, Sendable, CustomStringConvertible {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    /// Creates a position from chess-style notation, e.g. `"c2"`. Fails for
    /// strings outside a1–h4.
    public init?(_ notation: String) {
        guard notation.count == 2,
              let file = notation.first,
              let column = "abcdefgh".firstIndex(of: file).map({ "abcdefgh".distance(from: "abcdefgh".startIndex, to: $0) }),
              let rank = notation.last?.wholeNumberValue,
              (1...4).contains(rank)
        else { return nil }
        self.init(column: column, row: rank - 1)
    }

    public var notation: String {
        let file = "abcdefgh"
        guard (0..<8).contains(column), (0..<4).contains(row) else { return "(\(column),\(row))" }
        return String(file[file.index(file.startIndex, offsetBy: column)]) + String(row + 1)
    }

    public var description: String { notation }

    public func shifted(_ direction: Direction) -> Position {
        Position(column: column + direction.deltaColumn, row: row + direction.deltaRow)
    }
}

public enum Direction: String, CaseIterable, Codable, Sendable {
    case up, down, left, right

    public var deltaColumn: Int {
        switch self {
        case .left: -1
        case .right: 1
        case .up, .down: 0
        }
    }

    public var deltaRow: Int {
        switch self {
        case .up: 1
        case .down: -1
        case .left, .right: 0
        }
    }
}
