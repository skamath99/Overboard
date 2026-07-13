import SwiftUI
import PushFightCore

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if history.matches.isEmpty {
                ContentUnavailableView(
                    "No games yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Finished games appear here so you can replay them move by move.")
                )
                .foregroundStyle(.white)
            } else {
                List {
                    ForEach(history.matches) { match in
                        // View-destination link: the rest of the app navigates
                        // view-based, and mixing in value-based links makes
                        // the pushed screen pop straight back.
                        NavigationLink {
                            ReplayView(match: match)
                        } label: {
                            HistoryRow(match: match)
                        }
                        .listRowBackground(Color.white.opacity(0.06))
                    }
                    .onDelete { history.delete(at: $0) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Match History")
    }
}

private struct HistoryRow: View {
    let match: MatchRecord

    var body: some View {
        HStack(spacing: 12) {
            resultBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    if match.mode == .ranked {
                        Image(systemName: "trophy.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.lastMove)
                    }
                    Text(match.mode.label)
                    Text("·")
                    Text(match.date, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let eloChange = match.eloChange {
                Text(eloChange >= 0 ? "+\(eloChange)" : "\(eloChange)")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(eloChange >= 0 ? .green : Theme.anchor)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch match.mode {
        case .local:
            if let winner = match.winner {
                return "\(Theme.playerName(winner)) won"
            }
            return "Pass & Play"
        case .friend, .ranked, .computer:
            let name = match.opponentName ?? "Opponent"
            switch match.localPlayerWon {
            case true: return "Won vs \(name)"
            case false: return "Lost vs \(name)"
            default: return "vs \(name)"
            }
        }
    }

    private var resultBadge: some View {
        let (symbol, color): (String, Color) = {
            switch match.localPlayerWon {
            case true: ("trophy.fill", Theme.lastMove)
            case false: ("xmark", Theme.anchor)
            default: ("flag.checkered", Theme.accent)
            }
        }()
        return Image(systemName: symbol)
            .font(.subheadline.bold())
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(Circle().fill(.white.opacity(0.08)))
    }
}
