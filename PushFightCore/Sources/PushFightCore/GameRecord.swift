import Foundation

/// A complete game as an ordered log of actions. The current ``state`` is
/// always derivable by replaying the log, which gives three things for free:
/// compact serialization (only actions are encoded), move-by-move replay for
/// match history, and undo during a turn.
public struct GameRecord: Equatable, Sendable {
    public private(set) var actions: [Action]
    public private(set) var state: GameState

    public init() {
        actions = []
        state = GameState()
    }

    public init(actions: [Action]) throws {
        self.actions = actions
        var replayed = GameState()
        for action in actions {
            try replayed.apply(action)
        }
        state = replayed
    }

    /// Validates the action against the current state and appends it.
    public mutating func apply(_ action: Action) throws {
        try state.apply(action)
        actions.append(action)
    }

    /// Reverts the most recent action by replaying the shortened log.
    /// Useful for undo before a turn is committed with a push.
    public mutating func undoLastAction() {
        guard !actions.isEmpty else { return }
        // Replay cost is negligible: games are tens of actions on a 26-tile board.
        self = try! GameRecord(actions: Array(actions.dropLast()))
    }

    /// The state after the first `count` actions, for replay scrubbing.
    /// `count` is clamped to the valid range.
    public func state(afterActions count: Int) -> GameState {
        let count = max(0, min(count, actions.count))
        return (try? GameRecord(actions: Array(actions.prefix(count))).state) ?? GameState()
    }

    public var winner: Player? {
        if case .finished(let winner) = state.phase { return winner }
        return nil
    }
}

extension GameRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case actions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actions: container.decode([Action].self, forKey: .actions))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actions, forKey: .actions)
    }
}

extension GameRecord {
    public func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(serialized data: Data) throws {
        self = try JSONDecoder().decode(GameRecord.self, from: data)
    }
}
