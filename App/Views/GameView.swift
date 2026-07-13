import SwiftUI
import PushFightCore

/// Hosts one game session: local pass-and-play or an online match.
struct GameView: View {
    @ObservedObject var session: GameSession
    var opponentName: String?
    /// False while an online match is still waiting for auto-match to fill
    /// the second seat.
    var opponentJoined = true
    var onResign: (() -> Void)?
    /// Cancels an online match nobody has joined yet.
    var onCancel: (() -> Void)?
    var onExit: () -> Void
    var onRematch: (() -> Void)?

    @State private var showResignConfirmation = false
    @State private var showCancelConfirmation = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                header
                if !opponentJoined, session.winner == nil {
                    waitingBanner
                }
                BoardView(
                    state: session.state,
                    tracker: session.tracker,
                    selection: session.selection,
                    moveTargets: session.moveTargets,
                    pushTargets: session.pushTargets,
                    placementTargets: session.interactionEnabled ? session.placementTargets : [],
                    perspective: perspective,
                    onTap: { session.tap($0) }
                )
                .padding(.horizontal, 8)
                controls
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            if case .finished(let winner) = session.state.phase {
                winOverlay(winner: winner)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onExit()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .tint(.white)
            }
            if onCancel != nil, !opponentJoined {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel Match", role: .destructive) {
                        showCancelConfirmation = true
                    }
                    .tint(Theme.anchor)
                }
            } else if onResign != nil, opponentJoined, session.winner == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Resign", role: .destructive) {
                        showResignConfirmation = true
                    }
                    .tint(Theme.anchor)
                }
            }
        }
        .confirmationDialog("Resign this match?", isPresented: $showResignConfirmation, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { onResign?() }
        }
        .confirmationDialog("Cancel this match?", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            Button("Cancel Match", role: .destructive) { onCancel?() }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("No one has joined yet. Cancelling removes the match — no result is recorded.")
        }
    }

    private var waitingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.lastMove)
            Text("Waiting for an opponent to join…")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(0.08)))
        .padding(.horizontal, 24)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                playerBadge(.one)
                Text("vs")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                playerBadge(.two)
            }
            Text(statusLine)
                .font(.headline)
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: statusLine)
                .accessibilityIdentifier("game-status")
        }
    }

    private func playerBadge(_ player: Player) -> some View {
        let isActive = session.winner == nil && session.actingPlayer == player
        return HStack(spacing: 8) {
            Circle()
                .fill(Theme.playerSwatch(player))
                .frame(width: 14, height: 14)
            Text(name(of: player))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(isActive ? 0.18 : 0.05)))
        .overlay(Capsule().strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 1.5))
    }

    /// Online and computer players always see their own side at the bottom.
    private var perspective: Player {
        switch session.mode {
        case .online(let localSide): localSide
        case .computer(let humanSide, _): humanSide
        case .local: .one
        }
    }

    private func name(of player: Player) -> String {
        switch session.mode {
        case .online(let localSide):
            return player == localSide ? "You" : (opponentName ?? "Opponent")
        case .computer(let humanSide, let level):
            return player == humanSide ? "You" : level.displayName
        case .local:
            return Theme.playerName(player)
        }
    }

    private func winText(_ winner: Player) -> String {
        let name = name(of: winner)
        return name == "You" ? "You win!" : "\(name) wins!"
    }

    private var statusLine: String {
        switch session.state.phase {
        case .placement:
            guard let placer = session.state.placingPlayer else { return "" }
            if !session.interactionEnabled { return "\(name(of: placer)) is placing pieces…" }
            let squares = session.remainingToPlace(.square, for: placer)
            let rounds = session.remainingToPlace(.round, for: placer)
            return "\(name(of: placer)): place \(squares) square\(squares == 1 ? "" : "s"), \(rounds) round\(rounds == 1 ? "" : "s")"
        case .playing:
            let current = session.state.currentPlayer
            if !session.interactionEnabled {
                if case .computer = session.mode { return "\(name(of: current)) is thinking…" }
                return "Waiting for \(name(of: current))…"
            }
            let movesLeft = session.state.movesRemaining
            return movesLeft > 0
                ? "\(name(of: current)): \(movesLeft) move\(movesLeft == 1 ? "" : "s") left, then push"
                : "\(name(of: current)): you must push"
        case .finished(let winner):
            return winText(winner)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            if session.state.phase == .placement, session.interactionEnabled, let placer = session.state.placingPlayer {
                placementTray(for: placer)
            }
            if session.undoableCount > 0, session.interactionEnabled {
                Button {
                    session.undoLastMove()
                } label: {
                    Label("Undo move", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(minHeight: 48)
    }

    private func placementTray(for placer: Player) -> some View {
        HStack(spacing: 10) {
            ForEach(PieceKind.allCases, id: \.self) { kind in
                let remaining = session.remainingToPlace(kind, for: placer)
                Button {
                    session.placementKind = kind
                } label: {
                    HStack(spacing: 6) {
                        PieceView(
                            piece: Piece(owner: placer, kind: kind),
                            hasAnchor: false,
                            isSelected: false,
                            size: 26
                        )
                        Text("×\(remaining)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(.white.opacity(session.placementKind == kind ? 0.2 : 0.06))
                    )
                    .overlay(
                        Capsule().strokeBorder(session.placementKind == kind ? Theme.accent : .clear, lineWidth: 1.5)
                    )
                }
                .disabled(remaining == 0)
                .opacity(remaining == 0 ? 0.4 : 1)
            }
        }
    }

    // MARK: - Win overlay

    private func winOverlay(winner: Player) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.lastMove)
                Text(winText(winner))
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text(winDetail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    if let onRematch {
                        Button("Rematch") { onRematch() }
                            .buttonStyle(MenuButtonStyle(prominent: true))
                    }
                    Button("Done") { onExit() }
                        .buttonStyle(MenuButtonStyle())
                }
                .frame(maxWidth: 240)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: 0x222B40))
                    .shadow(radius: 30)
            )
            .padding(40)
        }
        .transition(.opacity)
    }

    private var winDetail: String {
        session.state.pieces.count < GameState.piecesPerPlayer * 2
            ? "A piece was pushed off the board."
            : "No legal push remained — a player who cannot push loses."
    }
}

private extension GameSession {
    var winner: Player? { record.winner }
}
