import Foundation
import GameKit
import PushFightCore

/// The local player's Elo rating. Persisted in UserDefaults and mirrored to a
/// Game Center leaderboard (best-effort) so opponents' ratings are visible.
@MainActor
final class EloStore: ObservableObject {
    /// Configure a leaderboard with this ID in App Store Connect.
    static let leaderboardID = "pushfight.elo"
    private static let ratingKey = "pushfight.elo.rating"
    private static let gamesKey = "pushfight.elo.games"

    @Published private(set) var rating: Int
    @Published private(set) var rankedGamesPlayed: Int

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.ratingKey)
        rating = stored == 0 ? Elo.defaultRating : stored
        rankedGamesPlayed = UserDefaults.standard.integer(forKey: Self.gamesKey)
    }

    var matchmakingGroup: Int {
        Elo.matchmakingGroup(for: rating)
    }

    /// Applies a ranked result and returns the local player's rating delta.
    @discardableResult
    func recordRankedGame(won: Bool, opponentRating: Int) -> Int {
        let updated = won
            ? Elo.updatedRatings(winner: rating, loser: opponentRating).winner
            : Elo.updatedRatings(winner: opponentRating, loser: rating).loser
        let delta = updated - rating
        rating = updated
        rankedGamesPlayed += 1
        UserDefaults.standard.set(rating, forKey: Self.ratingKey)
        UserDefaults.standard.set(rankedGamesPlayed, forKey: Self.gamesKey)
        submitToLeaderboard()
        return delta
    }

    private func submitToLeaderboard() {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        GKLeaderboard.submitScore(
            rating,
            context: 0,
            player: GKLocalPlayer.local,
            leaderboardIDs: [Self.leaderboardID]
        ) { _ in }
    }
}
