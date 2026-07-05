import Foundation

/// Standard Elo rating math, used for ranked auto-match games.
public enum Elo {
    public static let defaultRating = 1200
    public static let kFactor = 32.0

    /// Probability that `rating` beats `opponent` (0...1).
    public static func expectedScore(_ rating: Int, against opponent: Int) -> Double {
        1.0 / (1.0 + pow(10.0, Double(opponent - rating) / 400.0))
    }

    /// New ratings after a decisive game.
    public static func updatedRatings(
        winner: Int,
        loser: Int,
        k: Double = kFactor
    ) -> (winner: Int, loser: Int) {
        let expectedWin = expectedScore(winner, against: loser)
        let delta = Int((k * (1.0 - expectedWin)).rounded())
        return (winner + delta, loser - delta)
    }
}
