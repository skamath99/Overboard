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
    /// The invite code for party matches, so the creator can re-read it while
    /// the match waits for the friend.
    var partyCode: String?

    init(game: GameRecord, ranked: Bool, ratings: [String: Int], seatZeroSide: Player = .two, partyCode: String? = nil) {
        self.game = game
        self.ranked = ranked
        self.ratings = ratings
        self.seatZeroSide = seatZeroSide
        self.partyCode = partyCode
    }

    private enum CodingKeys: String, CodingKey {
        case game, ranked, ratings, seatZeroSide, partyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        game = try container.decode(GameRecord.self, forKey: .game)
        ranked = try container.decode(Bool.self, forKey: .ranked)
        ratings = try container.decode([String: Int].self, forKey: .ratings)
        seatZeroSide = try container.decodeIfPresent(Player.self, forKey: .seatZeroSide) ?? .two
        partyCode = try container.decodeIfPresent(String.self, forKey: .partyCode)
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
    /// A party code from a deep link that arrived before authentication; joined
    /// as soon as sign-in completes.
    private var pendingJoinCode: String?

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
                    // Honor a deep link that arrived before we were signed in.
                    if let code = self.pendingJoinCode {
                        self.pendingJoinCode = nil
                        await self.joinParty(code: code)
                    }
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

    /// Ranked lobby: auto-match against a stranger from the global queue.
    func findRankedMatch() async {
        guard isAuthenticated else { return }
        isFindingRankedMatch = true
        defer { isFindingRankedMatch = false }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        // Ranked uses a single global pool: Game Center only pairs equal
        // `playerGroup` values, so rating bands would strand a small player
        // base in separate buckets. Add banding back once the population
        // justifies it.
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            open(match, rankedIfNew: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Base request for a direct friend/recent-player invite.
    var friendMatchRequest: GKMatchRequest {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "Let's play Overboard!"
        return request
    }

    /// Creates a turn-based match inviting a specific friend, then opens it
    /// through the usual lobby/board flow. Returns whether the match was
    /// created (so callers can keep their UI up on failure).
    @discardableResult
    func invite(_ player: GKPlayer) async -> Bool {
        let request = friendMatchRequest
        request.recipients = [player]
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            open(match)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Party-code invites

    /// Unambiguous code alphabet (no O/0, I/1, L, etc.).
    private static let partyCodeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Deterministic `playerGroup` for a party code, agreed across devices and
    /// processes (Swift's `Hasher` is per-process seeded, so never use it).
    /// SHA256 the uppercased code, folded to 31 bits (values beyond 32 bits
    /// are unproven against the matchmaking service), mapping 0 → 1 so we
    /// never collide with the global pool (0).
    static func partyGroup(for code: String) -> Int {
        let digest = SHA256.hash(data: Data(code.uppercased().utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        value &= 0x7fff_ffff
        return Int(value == 0 ? 1 : value)
    }

    private static func makePartyCode() -> String {
        String((0..<6).map { _ in partyCodeAlphabet.randomElement()! })
    }

    /// Creates a private waiting match keyed to a fresh party code and returns
    /// the code. The friend enters the same private pool by typing the code,
    /// and Game Center pairs them.
    func createPartyInvite() async -> String? {
        guard isAuthenticated else { return nil }
        let code = Self.makePartyCode()
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.playerGroup = Self.partyGroup(for: code)
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            // No lobby banner: the share step communicates the waiting state, and
            // setting lobbyMessage here would race the picker's own presentation.
            open(match, lobbyNotice: .none, partyCode: code)
            return code
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Joins the private pool for a party code; Game Center pairs the joiner
    /// with the inviter's waiting match since the `playerGroup`s are equal.
    func joinParty(code: String) async {
        guard isAuthenticated else { return }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.playerGroup = Self.partyGroup(for: normalized)
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            open(match)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Handles an incoming deep link, accepting both `overboard://join/<CODE>`
    /// (and `overboard://join?code=`) and the https share link with `?code=`.
    func handleIncomingURL(_ url: URL) {
        guard let code = Self.partyCode(from: url) else { return }
        if isAuthenticated {
            Task { await joinParty(code: code) }
        } else {
            pendingJoinCode = code
        }
    }

    private static func partyCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query = components?.queryItems?.first(where: { $0.name == "code" })?.value,
           !query.isEmpty {
            return query
        }
        // `overboard://join/<CODE>`: host is "join", code is the path segment.
        let segments = url.pathComponents.filter { $0 != "/" }
        if url.host == "join", let last = segments.last, !last.isEmpty {
            return last
        }
        return nil
    }

    /// Opens a match. Creators of fresh matches don't get a board: the empty
    /// first turn is handed straight to the opponent's seat, which is what
    /// enters the match into Game Center's matchmaking pool. The board only
    /// appears once it's genuinely this player's turn to act.
    /// Controls the lobby banner shown when a fresh match hands its turn away.
    enum LobbyNotice {
        /// The default automatch/invite-pending texts.
        case standard
        /// A caller-supplied message.
        case custom(String)
        /// No banner (e.g. party invites, whose share UI already explains).
        case none
    }

    func open(_ match: GKTurnBasedMatch, rankedIfNew: Bool = false, lobbyNotice: LobbyNotice = .standard, partyCode: String? = nil) {
        var payload = OnlineMatchPayload.decode(match.matchData, ranked: rankedIfNew)

        // Brand-new match (no data written yet): pick which side the creator
        // plays so both clients agree once we save the payload.
        let isFreshMatch = match.matchData?.isEmpty ?? true
        if isFreshMatch {
            payload.seatZeroSide = Bool.random() ? .one : .two
            payload.partyCode = partyCode
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
        // a board with nothing to do. A brand-new match ALWAYS hands the empty
        // first turn away — that is what enters it into the matchmaking pool
        // (or sends the invite) — even when the creator drew the side that
        // places first: the joiner's client bounces the turn straight back
        // through this same branch, and only then does the creator set up.
        let actingSide = payload.game.state.placingPlayer ?? payload.game.state.currentPlayer
        if payload.game.winner == nil, actingSide != localSide || isFreshMatch, holdsTurn(in: match, actionsEmpty: payload.game.actions.isEmpty) {
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
            switch lobbyNotice {
            case .standard:
                // Seat 0 is the creator; anyone else is a joiner bouncing the
                // setup turn back to a creator who places first.
                if (match.localParticipantIndex ?? 0) != 0 {
                    lobbyMessage = "You're in! Your opponent sets up first — you'll be notified when it's your move."
                } else if match.hasJoinedOpponent {
                    lobbyMessage = "Invite sent! You'll be notified when it's your turn."
                } else {
                    lobbyMessage = "You're in the matchmaking pool. You'll be notified when an opponent joins."
                }
            case .custom(let text):
                lobbyMessage = text
            case .none:
                break
            }
            return
        }

        let session = GameSession(mode: .online(localSide: localSide), record: payload.game)
        let online = OnlineMatch(match: match, session: session, localSide: localSide, payload: payload)
        session.onActionCommitted = { [weak self, weak online] record, turnEnded in
            guard let self, let online else { return }
            self.commit(record, turnEnded: turnEnded, in: online)
        }
        activeMatch = online

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
