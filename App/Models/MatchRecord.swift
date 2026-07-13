import Foundation
import PushFightCore

/// A finished (or abandoned) game as stored in local match history.
struct MatchRecord: Identifiable, Codable, Equatable {
    enum Mode: String, Codable {
        case local
        case friend
        case ranked
        case computer

        var label: String {
            switch self {
            case .local: "Pass & Play"
            case .friend: "Friend Match"
            case .ranked: "Ranked"
            case .computer: "vs Computer"
            }
        }
    }

    let id: UUID
    let date: Date
    let mode: Mode
    let game: GameRecord
    /// Which side the local player controlled; nil for pass-and-play.
    let localSide: Player?
    let opponentName: String?
    /// Elo delta applied to the local player, ranked games only.
    let eloChange: Int?

    var winner: Player? { game.winner }

    var localPlayerWon: Bool? {
        guard let winner, let localSide else { return nil }
        return winner == localSide
    }
}
