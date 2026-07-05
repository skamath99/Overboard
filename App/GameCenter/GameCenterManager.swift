import SwiftUI
import GameKit
import CryptoKit
import PushFightCore

/// Everything stored in `GKTurnBasedMatch.matchData`.
struct OnlineMatchPayload: Codable {
    var game: GameRecord
    var ranked: Bool
    /// Self-reported Elo by `gamePlayerID`, exchanged for rating updates.
    var ratings: [String: Int]
    /// Which side the match creator (seat 0) plays. Randomized per match so
    /// both clients agree; defaults to `.two` for matches created before this
    /// field existed.
    var seatZeroSide: Player

    init(game: GameRecord, ranked: Bool, ratings: [String: Int], seatZeroSide: Player = .two) {
        self.game = game
        self.ranked = ranked
        self.ratings = ratings
        self.seatZeroSide = seatZeroSide
    }

    private enum CodingKeys: String, CodingKey {
        case game, ranked, ratings, seatZeroSide
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        game = try container.decode(GameRecord.self, forKey: .game)
        ranked = try container.decode(Bool.self, forKey: .ranked)
        ratings = try container.decode([String: Int].self, forKey: .ratings)
        seatZeroSide = try container.decodeIfPresent(Player.self, forKey: .seatZeroSide) ?? .two
    }

    func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Seat 0 (the creator) plays `seatZeroSide`; the other seat plays its
    /// opponent.
    func side(forParticipantIndex index: Int) -> Player {
        index == 0 ? seatZeroSide : seatZeroSide.opponent
    }

    static func decode(_ data: Data?, ranked fallbackRanked: Bool = false) -> OnlineMatchPayload {
        guard let data, !data.isEmpty,
              let payload = try? JSONDecoder().decode(OnlineMatchPayload.self, from: data)
        else {
            return OnlineMatchPayload(game: GameRecord(), ranked: fallbackRanked, ratings: [:], seatZeroSide: .two)
        }
        return payload
    }
}

extension GKTurnBasedMatch {
    /// Player-ID comparison alone is unreliable in the sandbox, so compare
    /// both scoped identifiers.
    nonisolated static func isLocal(_ participant: GKTurnBasedParticipant) -> Bool {
        guard let player = participant.player else { return false }
        return player.gamePlayerID == GKLocalPlayer.local.gamePlayerID
            || player.teamPlayerID == GKLocalPlayer.local.teamPlayerID
    }

    var localParticipantIndex: Int? {
        participants.firstIndex { Self.isLocal($0) }
    }

    var otherParticipants: [GKTurnBasedParticipant] {
        if let mine = localParticipantIndex {
            return participants.enumerated().filter { $0.offset != mine }.map(\.element)
        }
        // Our own player object can be missing right after creating a match,
        // and only the creator can be in that state — we hold seat 0.
        return Array(participants.dropFirst())
    }

    /// False while an auto-match seat is still waiting to be filled.
    var hasJoinedOpponent: Bool {
        otherParticipants.contains { $0.player != nil }
    }
}

/// An online game the UI is currently showing.
@MainActor
final class OnlineMatch: Identifiable, Hashable {
    private(set) var match: GKTurnBasedMatch
    let session: GameSession
    let localSide: Player
    var payload: OnlineMatchPayload

    nonisolated let id: String

    var opponentJoined: Bool {
        match.hasJoinedOpponent
    }

    var opponentName: String {
        match.otherParticipants.first { $0.player != nil }?.player?.displayName ?? "Opponent"
    }

    init(match: GKTurnBasedMatch, session: GameSession, localSide: Player, payload: OnlineMatchPayload) {
        self.id = match.matchID
        self.match = match
        self.session = session
        self.localSide = localSide
        self.payload = payload
    }

    /// Turn events deliver a fresh match object; keep ours current so
    /// participant state (like a newly joined opponent) is visible.
    func update(from match: GKTurnBasedMatch) {
        guard match.matchID == id else { return }
        self.match = match
    }

    nonisolated static func == (lhs: OnlineMatch, rhs: OnlineMatch) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class GameCenterManager: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authStatus = "Connecting to Game Center…"
    @Published var activeMatch: OnlineMatch?
    @Published private(set) var openMatches: [GKTurnBasedMatch] = []
    @Published var isFindingRankedMatch = false
    @Published var lastError: String?
    /// Shown after creating a match, while waiting for the opponent's setup.
    @Published var lobbyMessage: String?
    /// One-off announcement (e.g. an opponent resigning the active game).
    @Published var notice: String?

    private weak var eloStore: EloStore?
    private weak var historyStore: HistoryStore?

    func configure(eloStore: EloStore, historyStore: HistoryStore) {
        self.eloStore = eloStore
        self.historyStore = historyStore
    }

    // MARK: - Authentication

    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    Self.rootViewController?.present(viewController, animated: true)
                    return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    self.isAuthenticated = true
                    self.authStatus = "Signed in as \(GKLocalPlayer.local.displayName)"
                    GKLocalPlayer.local.register(self)
                    await self.refreshOpenMatches()
                } else {
                    self.isAuthenticated = false
                    self.authStatus = error.map { "Game Center unavailable: \($0.localizedDescription)" }
                        ?? "Sign in to Game Center in Settings to play online."
                }
            }
        }
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }

    // MARK: - Starting matches

    /// Ranked lobby: auto-match against a stranger in the same Elo band.
    func findRankedMatch() async {
        guard isAuthenticated, let eloStore else { return }
        isFindingRankedMatch = true
        defer { isFindingRankedMatch = false }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.playerGroup = eloStore.matchmakingGroup
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            open(match, rankedIfNew: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Friend match: present Game Center's invite UI.
    var friendMatchRequest: GKMatchRequest {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "Let's play Overboard!"
        return request
    }

    /// Opens a match. Creators of fresh matches don't get a board: the empty
    /// first turn is handed straight to the opponent's seat, which is what
    /// enters the match into Game Center's matchmaking pool. The board only
    /// appears once it's genuinely this player's turn to act.
    func open(_ match: GKTurnBasedMatch, rankedIfNew: Bool = false) {
        var payload = OnlineMatchPayload.decode(match.matchData, ranked: rankedIfNew)

        // Brand-new match (no data written yet): pick which side the creator
        // plays so both clients agree once we save the payload.
        let isFreshMatch = match.matchData?.isEmpty ?? true
        if isFreshMatch {
            payload.seatZeroSide = Bool.random() ? .one : .two
        }

        // Register our rating the first time we touch a ranked match.
        let myID = GKLocalPlayer.local.gamePlayerID
        if payload.ranked, payload.ratings[myID] == nil, let eloStore {
            payload.ratings[myID] = eloStore.rating
        }

        let localSide: Player
        if let index = match.localParticipantIndex {
            localSide = payload.side(forParticipantIndex: index)
        } else {
            // Identity can lag on fresh matches; only the creator (seat 0)
            // can be looking at an empty game.
            localSide = payload.side(forParticipantIndex: payload.game.actions.isEmpty ? 0 : 1)
        }

        // If we hold the Game Center turn but the engine's next action
        // belongs to the other seat, pass the turn along instead of showing
        // a board with nothing to do. For a brand-new match this is the
        // creator handing the setup turn to the joiner.
        let actingSide = payload.game.state.placingPlayer ?? payload.game.state.currentPlayer
        if payload.game.winner == nil, actingSide != localSide, holdsTurn(in: match, actionsEmpty: payload.game.actions.isEmpty) {
            let data = (try? payload.serialized()) ?? Data()
            match.endTurn(
                withNextParticipants: match.otherParticipants,
                turnTimeout: GKTurnTimeoutDefault,
                match: data
            ) { [weak self] error in
                Task { @MainActor in
                    // Tapping a stale row can re-pass a turn we no longer own;
                    // those turn-state errors are benign and shouldn't alert.
                    if let error, !Self.isBenignTurnError(error) {
                        self?.lastError = error.localizedDescription
                    }
                    await self?.refreshOpenMatches()
                }
            }
            lobbyMessage = match.hasJoinedOpponent
                ? "Invite sent! Your friend sets up their side first — you'll be notified when it's your move."
                : "You're in the matchmaking pool. You'll be notified when an opponent joins and sets up their side."
            return
        }

        let session = GameSession(mode: .online(localSide: localSide), record: payload.game)
        let online = OnlineMatch(match: match, session: session, localSide: localSide, payload: payload)
        session.onActionCommitted = { [weak self, weak online] record, turnEnded in
            guard let self, let online else { return }
            self.commit(record, turnEnded: turnEnded, in: online)
        }
        activeMatch = online

        // Persist a fresh match's payload right away so the randomized
        // `seatZeroSide` is committed before the creator's first move. Without
        // this, a friend accepting in that window would decode empty data and
        // fall back to `.two`, diverging from the creator. Only for empty
        // match data, so we never clobber an existing game.
        if isFreshMatch, let data = try? payload.serialized() {
            match.saveCurrentTurn(withMatch: data) { _ in }
        }

        if case .finished = payload.game.state.phase {
            finalizeIfNeeded(online)
        }
    }

    /// Opens a match tapped from the home list. Reloads fresh Game Center
    /// data first so `open` doesn't act on a stale snapshot (which would try
    /// to re-pass a turn we no longer hold).
    func openFromHome(_ match: GKTurnBasedMatch) async {
        let fresh = (try? await GKTurnBasedMatch.load(withID: match.matchID)) ?? match
        open(fresh)
    }

    /// Turn-state errors raised when we act on a match snapshot that has since
    /// moved on. Harmless — a refresh reconciles the real state.
    private static func isBenignTurnError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == GKErrorDomain,
              let code = GKError.Code(rawValue: nsError.code) else { return false }
        switch code {
        case .turnBasedInvalidTurn, .turnBasedInvalidState, .turnBasedInvalidParticipant:
            return true
        default:
            return false
        }
    }

    /// Whether the local player currently holds the Game Center turn,
    /// tolerating the identity quirks of freshly created matches.
    private func holdsTurn(in match: GKTurnBasedMatch, actionsEmpty: Bool) -> Bool {
        guard let current = match.currentParticipant else { return false }
        if current.player != nil, GKTurnBasedMatch.isLocal(current) {
            return true
        }
        // An automatch seat holding the turn means we already passed it.
        if current.status == .matching {
            return false
        }
        // Fresh match with unresolved identities: the creator always starts
        // with the turn, and only the creator can see an empty game with no
        // joined opponent.
        return actionsEmpty && !match.hasJoinedOpponent
    }

    // MARK: - Turn handling

    private func commit(_ record: GameRecord, turnEnded: Bool, in online: OnlineMatch) {
        online.payload.game = record
        guard let data = try? online.payload.serialized() else { return }

        if case .finished(let winner) = record.state.phase {
            for (index, participant) in online.match.participants.enumerated() {
                let side = online.payload.side(forParticipantIndex: index)
                participant.matchOutcome = side == winner ? .won : .lost
            }
            online.match.endMatchInTurn(withMatch: data) { [weak self] error in
                Task { @MainActor in
                    if let error { self?.lastError = error.localizedDescription }
                    self?.finalizeIfNeeded(online)
                    await self?.refreshOpenMatches()
                }
            }
            return
        }

        if turnEnded {
            let others = online.match.otherParticipants
            online.match.endTurn(
                withNextParticipants: others,
                turnTimeout: GKTurnTimeoutDefault,
                match: data
            ) { [weak self] error in
                Task { @MainActor in
                    if let error { self?.lastError = error.localizedDescription }
                    await self?.refreshOpenMatches()
                }
            }
        } else {
            // Mid-turn save so force-quitting the app doesn't lose moves.
            online.match.saveCurrentTurn(withMatch: data) { _ in }
        }
    }

    func resign(_ online: OnlineMatch) {
        // Bailing before both sides finish placement isn't a real game: cancel
        // and remove it without recording a result or touching Elo.
        if case .placement = online.payload.game.state.phase {
            cancelMatch(online.match)
            return
        }
        let data = (try? online.payload.serialized()) ?? Data()
        let isMyTurn = online.match.currentParticipant.map { GKTurnBasedMatch.isLocal($0) } ?? false
        let completion: (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                self?.recordFinishedMatch(online, localWon: false)
                self?.activeMatch = nil
                await self?.refreshOpenMatches()
            }
        }
        if isMyTurn {
            online.match.participantQuitInTurn(
                with: .quit, nextParticipants: online.match.otherParticipants, turnTimeout: GKTurnTimeoutDefault, match: data, completionHandler: completion
            )
        } else {
            online.match.participantQuitOutOfTurn(with: .quit, withCompletionHandler: completion)
        }
    }

    /// Cancels a match nobody has joined (or cleans up a finished one):
    /// quits if needed, removes it from Game Center, and records nothing.
    func cancelMatch(_ match: GKTurnBasedMatch) {
        if activeMatch?.id == match.matchID {
            activeMatch = nil
        }
        let finish: () -> Void = { [weak self] in
            match.remove { _ in
                Task { @MainActor in await self?.refreshOpenMatches() }
            }
        }
        let isMyTurn = match.currentParticipant.map { GKTurnBasedMatch.isLocal($0) } ?? false
        if match.status != .ended, isMyTurn {
            match.participantQuitInTurn(
                with: .quit,
                nextParticipants: match.otherParticipants,
                turnTimeout: GKTurnTimeoutDefault,
                match: match.matchData ?? Data()
            ) { _ in finish() }
        } else if match.status != .ended {
            // GameKit rejects `remove` for a still-active participant with no
            // outcome, so quit out of turn first. Setting our outcome also lets
            // `localHasLeft` hide the match even if the remove itself fails.
            match.participantQuitOutOfTurn(with: .quit) { _ in finish() }
        } else {
            finish()
        }
    }

    /// Leaves any open match from the home list. A live game against a real
    /// opponent counts as a resignation (with Elo applied if ranked);
    /// anything else is just cancelled and removed.
    func abandon(_ match: GKTurnBasedMatch) {
        let payload = OnlineMatchPayload.decode(match.matchData)
        let started: Bool
        if case .placement = payload.game.state.phase { started = false } else { started = true }
        let live = match.status != .ended && payload.game.winner == nil && match.hasJoinedOpponent && started
        guard live else {
            cancelMatch(match)
            return
        }
        let localSide = payload.side(forParticipantIndex: match.localParticipantIndex ?? 0)
        let opponentName = match.otherParticipants.first { $0.player != nil }?.player?.displayName
        recordFinishedMatch(
            matchID: match.matchID,
            payload: payload,
            localSide: localSide,
            opponentName: opponentName,
            localWon: false
        )
        cancelMatch(match)
    }

    func refreshOpenMatches() async {
        guard isAuthenticated else { return }
        let matches = (try? await GKTurnBasedMatch.loadMatches()) ?? []
        // Close out matches an opponent abandoned before listing anything.
        for match in matches where opponentQuit(in: match) {
            finalizeOpponentQuit(match)
        }
        openMatches = matches
            .filter { $0.status == .open || $0.status == .matching }
            .filter { !localHasLeft($0) }
            .filter { !opponentQuit(in: $0) }
            .sorted { ($0.creationDate) > ($1.creationDate) }
    }

    /// Whether the local player has already left a match (resigned or
    /// finished), even if the match itself lingers as `.open`.
    private func localHasLeft(_ match: GKTurnBasedMatch) -> Bool {
        guard let local = match.participants.first(where: { GKTurnBasedMatch.isLocal($0) }) else {
            return false
        }
        return local.matchOutcome != .none || local.status == .done
    }

    /// Whether the opponent bailed out but nothing finished the match, so it
    /// lingers with the turn dumped on us.
    private func opponentQuit(in match: GKTurnBasedMatch) -> Bool {
        guard match.status != .ended else { return false }
        let payload = OnlineMatchPayload.decode(match.matchData)
        guard payload.game.winner == nil else { return false }
        let localOutcome = match.participants.first { GKTurnBasedMatch.isLocal($0) }?.matchOutcome ?? .none
        guard localOutcome == .none else { return false }
        return match.participants.contains { participant in
            participant.player != nil && !GKTurnBasedMatch.isLocal(participant)
                && (participant.matchOutcome != .none || participant.status == .done)
        }
    }

    /// Records a forfeit win for the local player and closes out a match the
    /// opponent abandoned. Safe to call repeatedly (recording dedupes, and the
    /// "started" gate keeps unfinished setups off the books).
    private func finalizeOpponentQuit(_ match: GKTurnBasedMatch) {
        let payload = OnlineMatchPayload.decode(match.matchData)
        let localSide = payload.side(forParticipantIndex: match.localParticipantIndex ?? 0)
        let opponentName = match.otherParticipants.first { $0.player != nil }?.player?.displayName
        recordFinishedMatch(
            matchID: match.matchID,
            payload: payload,
            localSide: localSide,
            opponentName: opponentName,
            localWon: true
        )
        // Set outcomes (the quitter's `.quit` stays) and, if we hold the turn,
        // end the match. Failing or not holding the turn is fine — the match
        // is excluded from the open list either way.
        match.participants.first { GKTurnBasedMatch.isLocal($0) }?.matchOutcome = .won
        let isMyTurn = match.currentParticipant.map { GKTurnBasedMatch.isLocal($0) } ?? false
        if match.status != .ended, isMyTurn {
            match.endMatchInTurn(withMatch: match.matchData ?? Data()) { _ in }
        }
    }

    // MARK: - Finishing

    /// Saves history and applies Elo exactly once per match (guarded by the
    /// deduplicating HistoryStore).
    private func finalizeIfNeeded(_ online: OnlineMatch) {
        guard let winner = online.payload.game.winner else { return }
        recordFinishedMatch(online, localWon: winner == online.localSide)
    }

    private func recordFinishedMatch(_ online: OnlineMatch, localWon: Bool) {
        recordFinishedMatch(
            matchID: online.match.matchID,
            payload: online.payload,
            localSide: online.localSide,
            opponentName: online.opponentName,
            localWon: localWon
        )
    }

    private func recordFinishedMatch(
        matchID: String,
        payload: OnlineMatchPayload,
        localSide: Player,
        opponentName: String?,
        localWon: Bool
    ) {
        guard let historyStore else { return }
        // A game only counts once both sides have finished placement — quitting
        // during setup leaves no history and no rating change.
        if case .placement = payload.game.state.phase { return }
        let recordID = UUID(deterministicFrom: matchID)
        guard !historyStore.matches.contains(where: { $0.id == recordID }) else { return }

        var eloChange: Int?
        if payload.ranked, let eloStore {
            let opponentRating = payload.ratings.first {
                $0.key != GKLocalPlayer.local.gamePlayerID
            }?.value ?? Elo.defaultRating
            eloChange = eloStore.recordRankedGame(won: localWon, opponentRating: opponentRating)
        }

        historyStore.add(MatchRecord(
            id: recordID,
            date: Date(),
            mode: payload.ranked ? .ranked : .friend,
            game: payload.game,
            localSide: localSide,
            opponentName: opponentName ?? "Opponent",
            eloChange: eloChange
        ))
    }
}

// MARK: - GKTurnBasedEventListener

extension GameCenterManager: GKLocalPlayerListener {
    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        Task { @MainActor in
            // An opponent resigning arrives as a turn event with the turn
            // dumped on us; finalize the forfeit rather than opening a board.
            if opponentQuit(in: match) {
                let opponentName = match.otherParticipants.first { $0.player != nil }?.player?.displayName ?? "Your opponent"
                let started: Bool
                if case .placement = OnlineMatchPayload.decode(match.matchData).game.state.phase {
                    started = false
                } else {
                    started = true
                }
                finalizeOpponentQuit(match)
                if let active = activeMatch, active.id == match.matchID {
                    // Nothing is recorded for an unstarted game, so don't claim a win.
                    notice = started
                        ? "\(opponentName) resigned — you win!"
                        : "\(opponentName) left the match."
                    activeMatch = nil
                }
                await refreshOpenMatches()
                return
            }
            if let active = activeMatch, active.id == match.matchID {
                active.update(from: match)
                let payload = OnlineMatchPayload.decode(match.matchData, ranked: active.payload.ranked)
                active.payload = payload
                active.session.sync(to: payload.game)
                finalizeIfNeeded(active)
            } else if didBecomeActive {
                open(match)
            }
            await refreshOpenMatches()
        }
    }

    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor in
            let ranked = OnlineMatchPayload.decode(match.matchData).ranked
            if let active = activeMatch, active.id == match.matchID {
                active.update(from: match)
                active.payload = OnlineMatchPayload.decode(match.matchData, ranked: ranked)
                active.session.sync(to: active.payload.game)
                if let winner = active.payload.game.winner {
                    recordFinishedMatch(active, localWon: winner == active.localSide)
                } else {
                    // Opponent quit mid-game: local player wins by forfeit.
                    recordFinishedMatch(active, localWon: true)
                }
            } else {
                // A match we weren't actively viewing ended — record it too
                // (dedupe makes double-recording safe).
                let payload = OnlineMatchPayload.decode(match.matchData, ranked: ranked)
                let localSide = payload.side(forParticipantIndex: match.localParticipantIndex ?? 0)
                let opponentName = match.otherParticipants.first { $0.player != nil }?.player?.displayName
                let localWon: Bool
                if let winner = payload.game.winner {
                    localWon = winner == localSide
                } else {
                    let outcome = match.participants.first { GKTurnBasedMatch.isLocal($0) }?.matchOutcome ?? .none
                    localWon = outcome == .won
                }
                recordFinishedMatch(
                    matchID: match.matchID,
                    payload: payload,
                    localSide: localSide,
                    opponentName: opponentName,
                    localWon: localWon
                )
            }
            await refreshOpenMatches()
        }
    }
}

extension UUID {
    /// A stable UUID derived from an arbitrary string (used to deduplicate
    /// match records by Game Center match ID).
    init(deterministicFrom string: String) {
        let digest = SHA256.hash(data: Data(string.utf8))
        let bytes = Array(digest.prefix(16))
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
