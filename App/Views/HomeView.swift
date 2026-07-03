import SwiftUI
import GameKit
import PushFightCore

struct HomeView: View {
    @EnvironmentObject private var gameCenter: GameCenterManager
    @EnvironmentObject private var elo: EloStore
    @EnvironmentObject private var history: HistoryStore

    @State private var localSession: GameSession?
    @State private var showFriendMatchmaker = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    titleArt
                    ratingCard
                    menu
                    if !gameCenter.openMatches.isEmpty {
                        openMatchesSection
                    }
                    Text(gameCenter.authStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .navigationDestination(item: $localSession) { session in
            GameView(
                session: session,
                onExit: {
                    saveLocalGameIfFinished(session)
                    localSession = nil
                },
                onRematch: {
                    saveLocalGameIfFinished(session)
                    localSession = GameSession(mode: .local)
                }
            )
        }
        .navigationDestination(item: activeMatchBinding) { online in
            GameView(
                session: online.session,
                opponentName: online.opponentName,
                onResign: { gameCenter.resign(online) },
                onExit: { gameCenter.activeMatch = nil }
            )
        }
        .sheet(isPresented: $showFriendMatchmaker) {
            MatchmakerView(request: gameCenter.friendMatchRequest) {
                showFriendMatchmaker = false
            }
            .ignoresSafeArea()
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { gameCenter.lastError = nil }
        } message: {
            Text(gameCenter.lastError ?? "")
        }
        .task {
            await gameCenter.refreshOpenMatches()
        }
    }

    // MARK: - Sections

    private var titleArt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                PieceView(piece: Piece(owner: .one, kind: .square), hasAnchor: false, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .two, kind: .round), hasAnchor: true, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .one, kind: .round), hasAnchor: false, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .two, kind: .square), hasAnchor: false, isSelected: false, size: 34)
            }
            Text("PUSH FIGHT")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .kerning(2)
            Text("Two moves. One push. No mercy.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 12)
    }

    private var ratingCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR RATING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(1)
                Text("\(elo.rating)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("RANKED GAMES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(1)
                Text("\(elo.rankedGamesPlayed)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                )
        )
    }

    private var menu: some View {
        VStack(spacing: 12) {
            Button {
                localSession = GameSession(mode: .local)
            } label: {
                Label("Pass & Play", systemImage: "person.2.fill")
            }
            .buttonStyle(MenuButtonStyle(prominent: true))

            Button {
                showFriendMatchmaker = true
            } label: {
                Label("Play a Friend", systemImage: "envelope.fill")
            }
            .buttonStyle(MenuButtonStyle())
            .disabled(!gameCenter.isAuthenticated)

            Button {
                Task { await gameCenter.findRankedMatch() }
            } label: {
                if gameCenter.isFindingRankedMatch {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Finding a match…")
                    }
                } else {
                    Label("Ranked Lobby", systemImage: "trophy.fill")
                }
            }
            .buttonStyle(MenuButtonStyle())
            .disabled(!gameCenter.isAuthenticated || gameCenter.isFindingRankedMatch)

            NavigationLink {
                HistoryView()
            } label: {
                Label("Match History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(MenuButtonStyle())
        }
    }

    private var openMatchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR ONLINE GAMES")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.5))
                .kerning(1)
            ForEach(gameCenter.openMatches, id: \.matchID) { match in
                Button {
                    gameCenter.open(match)
                } label: {
                    OpenMatchRow(match: match)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var activeMatchBinding: Binding<OnlineMatch?> {
        Binding(
            get: { gameCenter.activeMatch },
            set: { gameCenter.activeMatch = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { gameCenter.lastError != nil },
            set: { if !$0 { gameCenter.lastError = nil } }
        )
    }

    private func saveLocalGameIfFinished(_ session: GameSession) {
        guard session.record.winner != nil else { return }
        history.add(MatchRecord(
            id: UUID(),
            date: Date(),
            mode: .local,
            game: session.record,
            localSide: nil,
            opponentName: nil,
            eloChange: nil
        ))
    }
}

private struct OpenMatchRow: View {
    let match: GKTurnBasedMatch

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMyTurn ? "exclamationmark.circle.fill" : "hourglass")
                .foregroundStyle(isMyTurn ? Theme.lastMove : .white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(opponentName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(isMyTurn ? "Your turn" : (match.status == .matching ? "Waiting for an opponent…" : "Their turn"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    private var isMyTurn: Bool {
        match.currentParticipant?.player?.gamePlayerID == GKLocalPlayer.local.gamePlayerID
    }

    private var opponentName: String {
        match.participants
            .first { $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID }?
            .player?.displayName ?? "Open match"
    }
}
