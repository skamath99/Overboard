import SwiftUI
import PushFightCore

/// Drives one interactive game: selection state, legal-target highlighting,
/// applying actions, and handing finished/committed turns to its delegate.
@MainActor
final class GameSession: ObservableObject {
    enum Mode: Equatable {
        case local
        /// Online play: the local player controls exactly one side.
        case online(localSide: Player)
    }

    @Published private(set) var record: GameRecord
    @Published private(set) var tracker: PieceTracker
    @Published var selection: Position?
    @Published var placementKind: PieceKind = .square

    let mode: Mode
    /// Whether it is currently legal for the person holding the device to act.
    var interactionEnabled: Bool {
        switch mode {
        case .local:
            true
        case .online(let side):
            actingPlayer == side
        }
    }

    /// Called after each locally applied action, with the turn-complete flag
    /// (true when the action was a push or the game ended).
    var onActionCommitted: ((GameRecord, _ turnEnded: Bool) -> Void)?

    init(mode: Mode, record: GameRecord = GameRecord()) {
        self.mode = mode
        self.record = record
        self.tracker = PieceTracker(replaying: record)
    }

    var state: GameState { record.state }

    /// The player whose input is expected right now (placer or mover).
    var actingPlayer: Player {
        state.placingPlayer ?? state.currentPlayer
    }

    /// Updates the game from outside (e.g. an opponent's turn arriving).
    func sync(to newRecord: GameRecord) {
        guard newRecord.actions.count != record.actions.count else { return }
        withAnimation(.spring(duration: 0.45)) {
            record = newRecord
            tracker = PieceTracker(replaying: newRecord)
        }
        selection = nil
    }

    // MARK: - Derived highlight sets

    var moveTargets: Set<Position> {
        guard case .playing = state.phase,
              let selection,
              state.movesUsed < GameState.movesPerTurn,
              state.piece(at: selection)?.owner == state.currentPlayer
        else { return [] }
        return state.reachableTiles(from: selection)
    }

    /// Adjacent occupied tiles the selected square could push into.
    var pushTargets: Set<Position> {
        guard case .playing = state.phase,
              let selection,
              let piece = state.piece(at: selection),
              piece.owner == state.currentPlayer,
              piece.kind == .square
        else { return [] }
        var targets: Set<Position> = []
        for direction in Direction.allCases where state.canPush(from: selection, direction) {
            if case .tile(let next) = Board.edge(from: selection, direction) {
                targets.insert(next)
            }
        }
        return targets
    }

    var placementTargets: Set<Position> {
        guard let placer = state.placingPlayer else { return [] }
        return Set(Board.allTiles.filter {
            Board.homeColumns(for: placer).contains($0.column) && state.piece(at: $0) == nil
        })
    }

    func remainingToPlace(_ kind: PieceKind, for player: Player) -> Int {
        let max = kind == .square ? GameState.squaresPerPlayer : GameState.roundsPerPlayer
        return max - state.placedCount(for: player, kind: kind)
    }

    /// Actions this turn that can still be undone (moves made before pushing).
    var undoableCount: Int {
        guard case .playing = state.phase else { return 0 }
        return state.movesUsed
    }

    // MARK: - Input

    func tap(_ position: Position) {
        guard interactionEnabled else { return }
        switch state.phase {
        case .placement:
            let placerBefore = state.placingPlayer
            applyIfLegal(.place(placementKind, at: position))
            if state.placingPlayer != placerBefore {
                // Fresh tray for the next placer (or for game start).
                placementKind = .square
            } else if let placer = state.placingPlayer, remainingToPlace(placementKind, for: placer) == 0 {
                // Auto-switch to a kind the placer still has left.
                placementKind = PieceKind.allCases.first { remainingToPlace($0, for: placer) > 0 } ?? .square
            }
        case .playing:
            tapDuringPlay(position)
        case .finished:
            break
        }
    }

    private func tapDuringPlay(_ position: Position) {
        if position == selection {
            selection = nil
            return
        }
        if moveTargets.contains(position) {
            applyIfLegal(.move(from: selection!, to: position))
            selection = nil
            return
        }
        if pushTargets.contains(position), let selection {
            if let direction = Direction.allCases.first(where: { selection.shifted($0) == position }) {
                applyIfLegal(.push(from: selection, direction))
            }
            self.selection = nil
            return
        }
        if let piece = state.piece(at: position), piece.owner == state.currentPlayer {
            selection = position
        } else {
            selection = nil
        }
    }

    func undoLastMove() {
        guard undoableCount > 0 else { return }
        withAnimation(.spring(duration: 0.35)) {
            record.undoLastAction()
            tracker = PieceTracker(replaying: record)
        }
        selection = nil
        onActionCommitted?(record, false)
    }

    private func applyIfLegal(_ action: Action) {
        let before = record.state
        var updated = record
        guard (try? updated.apply(action)) != nil else { return }
        withAnimation(.spring(duration: 0.4)) {
            tracker.track(action, before: before)
            record = updated
        }
        var turnEnded = false
        switch action {
        case .place:
            // A placement turn ends when the placer changes (or play begins).
            turnEnded = state.placingPlayer != before.placingPlayer
        case .move:
            break
        case .push:
            turnEnded = true
        }
        if case .finished = state.phase { turnEnded = true }
        onActionCommitted?(record, turnEnded)
    }
}

extension GameSession: Identifiable, Hashable {
    nonisolated static func == (lhs: GameSession, rhs: GameSession) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Gives value-type pieces stable identities so SwiftUI can animate them
/// sliding between tiles. IDs are assigned in placement order, so two
/// trackers replaying the same action prefix agree — which lets the replay
/// viewer animate between arbitrary steps.
struct PieceTracker {
    private(set) var ids: [Position: Int] = [:]
    private var nextID = 0

    init(replaying actions: [Action]) {
        var replay = GameState()
        for action in actions {
            let before = replay
            try? replay.apply(action)
            track(action, before: before)
        }
    }

    init(replaying record: GameRecord) {
        self.init(replaying: record.actions)
    }

    mutating func track(_ action: Action, before: GameState) {
        switch action {
        case .place(_, let position):
            ids[position] = nextID
            nextID += 1
        case .move(let from, let to):
            if let id = ids.removeValue(forKey: from) {
                ids[to] = id
            }
        case .push(let from, let direction):
            guard let (line, _) = try? before.pushLine(from: from, direction) else { return }
            var moved: [Position: Int] = [:]
            for position in line {
                if case .tile(let destination) = Board.edge(from: position, direction),
                   let id = ids[position] {
                    moved[destination] = id
                }
                ids.removeValue(forKey: position)
            }
            ids.merge(moved) { _, new in new }
        }
    }
}
