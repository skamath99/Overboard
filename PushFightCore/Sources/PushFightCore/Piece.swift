public enum Player: String, Codable, CaseIterable, Sendable {
    /// Places first, moves first, sets up on columns a–d.
    case one
    /// Sets up on columns e–h.
    case two

    public var opponent: Player {
        self == .one ? .two : .one
    }
}

public enum PieceKind: String, Codable, CaseIterable, Sendable {
    /// Square pieces move and push.
    case square
    /// Round pieces only move.
    case round
}

public struct Piece: Hashable, Codable, Sendable {
    public let owner: Player
    public let kind: PieceKind

    public init(owner: Player, kind: PieceKind) {
        self.owner = owner
        self.kind = kind
    }
}
