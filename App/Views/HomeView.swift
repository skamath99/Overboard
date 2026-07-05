import SwiftUI
import GameKit
import PushFightCore

struct HomeView: View {
    @EnvironmentObject private var gameCenter: GameCenterManager
    @EnvironmentObject private var elo: EloStore
    @EnvironmentObject private var history: HistoryStore

    @State private var localSession: GameSession?
    @State private var showFriendMatchmaker = false
    @State private var matchPendingRemoval: GKTurnBasedMatch?
    @Environment(\.scenePhase) private var scenePhase

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
            .refreshable {
                await gameCenter.refreshOpenMatches()
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
                opponentJoined: online.opponentJoined,
                onResign: { gameCenter.resign(online) },
                onCancel: { gameCenter.cancelMatch(online.match) },
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
        .alert("You're in the lobby", isPresented: Binding(
            get: { gameCenter.lobbyMessage != nil },
            set: { if !$0 { gameCenter.lobbyMessage = nil } }
        )) {
            Button("OK") { gameCenter.lobbyMessage = nil }
        } message: {
            Text(gameCenter.lobbyMessage ?? "")
        }
        .alert("Match over", isPresented: Binding(
            get: { gameCenter.notice != nil },
            set: { if !$0 { gameCenter.notice = nil } }
        )) {
            Button("OK") { gameCenter.notice = nil }
        } message: {
            Text(gameCenter.notice ?? "")
        }
        .confirmationDialog(
            "Leave this match?",
            isPresented: Binding(
                get: { matchPendingRemoval != nil },
                set: { if !$0 { matchPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(removalIsResignation ? "Resign & Remove" : "Cancel Match", role: .destructive) {
                if let match = matchPendingRemoval {
                    gameCenter.abandon(match)
                }
                matchPendingRemoval = nil
            }
            Button("Keep Match", role: .cancel) { matchPendingRemoval = nil }
        } message: {
            Text(removalMessage)
        }
        .task {
            await gameCenter.refreshOpenMatches()
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up invitations and opponent moves when returning to the app.
            if phase == .active {
                Task { await gameCenter.refreshOpenMatches() }
            }
        }
    }

    // MARK: - Sections

    private var titleArt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                // Only squares can carry the anchor — same rule as the game.
                PieceView(piece: Piece(owner: .one, kind: .square), hasAnchor: true, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .two, kind: .round), hasAnchor: false, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .one, kind: .round), hasAnchor: false, isSelected: false, size: 34)
                PieceView(piece: Piece(owner: .two, kind: .square), hasAnchor: false, isSelected: false, size: 34)
            }
            Text("OVERBOARD!")
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

            NavigationLink {
                HowToPlayView()
            } label: {
                Label("How to Play", systemImage: "book.fill")
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
                SwipeableRow(
                    onTap: { Task { await gameCenter.openFromHome(match) } },
                    onLeave: { matchPendingRemoval = match }
                ) {
                    OpenMatchRow(match: match)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var removalIsResignation: Bool {
        guard let match = matchPendingRemoval else { return false }
        let payload = OnlineMatchPayload.decode(match.matchData)
        let started: Bool
        if case .placement = payload.game.state.phase { started = false } else { started = true }
        return match.status != .ended && match.hasJoinedOpponent && started
    }

    private var removalMessage: String {
        guard let match = matchPendingRemoval else { return "" }
        if removalIsResignation {
            return "An opponent has joined, so leaving counts as a resignation."
        }
        if match.status != .ended && match.hasJoinedOpponent {
            return "This match hasn't started yet, so leaving removes it without affecting your rating."
        }
        return "No one has joined this match yet. It will be removed without a result."
    }

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

/// Swipe left to reveal a Leave action — List-style swipe behaviour for
/// rows living inside a plain ScrollView.
private struct SwipeableRow<Content: View>: View {
    let onTap: () -> Void
    let onLeave: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var isRevealed = false
    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onLeave) {
                VStack(spacing: 4) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.body.weight(.semibold))
                    Text("Leave")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.anchor)
                )
            }
            .opacity(offset < -12 ? 1 : 0)

            Button {
                isRevealed ? close() : onTap()
            } label: {
                content
            }
            .offset(x: offset)
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let base: CGFloat = isRevealed ? -revealWidth : 0
                    offset = min(0, max(-revealWidth - 24, base + value.translation.width))
                }
                .onEnded { value in
                    let settled = (isRevealed ? -revealWidth : 0) + value.translation.width
                    withAnimation(.spring(duration: 0.3)) {
                        isRevealed = settled < -revealWidth / 2
                        offset = isRevealed ? -revealWidth : 0
                    }
                }
        )
    }

    private func close() {
        withAnimation(.spring(duration: 0.3)) {
            offset = 0
            isRevealed = false
        }
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
        guard let current = match.currentParticipant else { return false }
        return GKTurnBasedMatch.isLocal(current)
    }

    private var opponentName: String {
        match.participants
            .first { $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID }?
            .player?.displayName ?? "Open match"
    }
}
