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

    func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?, ranked fallbackRanked: Bool = false) -> OnlineMatchPayload {
        guard let data, !data.isEmpty,
              let payload = try? JSONDecoder().decode(OnlineMatchPayload.self, from: data)
        else {
            return OnlineMatchPayload(game: GameRecord(), ranked: fallbackRanked, ratings: [:])
        }
        return payload
    }
}

/// An online game the UI is currently showing.
@MainActor
final class OnlineMatch: Identifiable, Hashable {
    let match: GKTurnBasedMatch
    let session: GameSession
    let localSide: Player
    var payload: OnlineMatchPayload

    nonisolated let id: String

    var opponentName: String {
        match.participants
            .first { $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID }?
            .player?.displayName ?? "Opponent"
    }

    init(match: GKTurnBasedMatch, session: GameSession, localSide: Player, payload: OnlineMatchPayload) {
        self.id = match.matchID
        self.match = match
        self.session = session
        self.localSide = localSide
        self.payload = payload
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
        request.inviteMessage = "Let's play Push Fight!"
        return request
    }

    /// Opens a match into a playable session and navigates to it.
    func open(_ match: GKTurnBasedMatch, rankedIfNew: Bool = false) {
        var payload = OnlineMatchPayload.decode(match.matchData, ranked: rankedIfNew)

        // Register our rating the first time we touch a ranked match.
        let myID = GKLocalPlayer.local.gamePlayerID
        if payload.ranked, payload.ratings[myID] == nil, let eloStore {
            payload.ratings[myID] = eloStore.rating
        }

        let localSide: Player = match.participants.firstIndex {
            $0.player?.gamePlayerID == myID
        } == 0 ? .one : .two

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

    // MARK: - Turn handling

    private func commit(_ record: GameRecord, turnEnded: Bool, in online: OnlineMatch) {
        online.payload.game = record
        guard let data = try? online.payload.serialized() else { return }

        if case .finished(let winner) = record.state.phase {
            for participant in online.match.participants {
                let side: Player = participant == online.match.participants.first ? .one : .two
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
            let others = online.match.participants.filter {
                $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID
            }
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
        let data = (try? online.payload.serialized()) ?? Data()
        let isMyTurn = online.match.currentParticipant?.player?.gamePlayerID == GKLocalPlayer.local.gamePlayerID
        let completion: (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                self?.recordFinishedMatch(online, localWon: false)
                self?.activeMatch = nil
                await self?.refreshOpenMatches()
            }
        }
        if isMyTurn {
            let others = online.match.participants.filter {
                $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID
            }
            online.match.participantQuitInTurn(
                with: .quit, nextParticipants: others, turnTimeout: GKTurnTimeoutDefault, match: data, completionHandler: completion
            )
        } else {
            online.match.participantQuitOutOfTurn(with: .quit, withCompletionHandler: completion)
        }
    }

    func refreshOpenMatches() async {
        guard isAuthenticated else { return }
        let matches = (try? await GKTurnBasedMatch.loadMatches()) ?? []
        openMatches = matches
            .filter { $0.status == .open || $0.status == .matching }
            .sorted { ($0.creationDate) > ($1.creationDate) }
    }

    // MARK: - Finishing

    /// Saves history and applies Elo exactly once per match (guarded by the
    /// deduplicating HistoryStore).
    private func finalizeIfNeeded(_ online: OnlineMatch) {
        guard let winner = online.payload.game.winner else { return }
        recordFinishedMatch(online, localWon: winner == online.localSide)
    }

    private func recordFinishedMatch(_ online: OnlineMatch, localWon: Bool) {
        guard let historyStore else { return }
        let recordID = UUID(deterministicFrom: online.match.matchID)
        guard !historyStore.matches.contains(where: { $0.id == recordID }) else { return }

        var eloChange: Int?
        if online.payload.ranked, let eloStore {
            let opponentRating = online.payload.ratings.first {
                $0.key != GKLocalPlayer.local.gamePlayerID
            }?.value ?? Elo.defaultRating
            eloChange = eloStore.recordRankedGame(won: localWon, opponentRating: opponentRating)
        }

        historyStore.add(MatchRecord(
            id: recordID,
            date: Date(),
            mode: online.payload.ranked ? .ranked : .friend,
            game: online.payload.game,
            localSide: online.localSide,
            opponentName: online.opponentName,
            eloChange: eloChange
        ))
    }
}

// MARK: - GKTurnBasedEventListener

extension GameCenterManager: GKLocalPlayerListener {
    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        Task { @MainActor in
            if let active = activeMatch, active.match.matchID == match.matchID {
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
            if let active = activeMatch, active.match.matchID == match.matchID {
                active.payload = OnlineMatchPayload.decode(match.matchData, ranked: ranked)
                active.session.sync(to: active.payload.game)
                if let winner = active.payload.game.winner {
                    recordFinishedMatch(active, localWon: winner == active.localSide)
                } else {
                    // Opponent quit mid-game: local player wins by forfeit.
                    recordFinishedMatch(active, localWon: true)
                }
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
