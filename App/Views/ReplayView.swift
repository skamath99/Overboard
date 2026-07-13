import SwiftUI
import PushFightCore

/// Steps through a finished game action by action.
struct ReplayView: View {
    let match: MatchRecord

    @State private var step: Int
    @State private var isAutoPlaying = false

    init(match: MatchRecord) {
        self.match = match
        _step = State(initialValue: match.game.actions.count)
    }

    private var totalSteps: Int { match.game.actions.count }
    private var shownState: GameState { match.game.state(afterActions: step) }
    private var shownTracker: PieceTracker {
        PieceTracker(replaying: Array(match.game.actions.prefix(step)))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                BoardView(state: shownState, tracker: shownTracker, perspective: match.localSide ?? .one)
                    .padding(.horizontal, 8)

                Text(caption)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)
                    .padding(.horizontal)

                VStack(spacing: 14) {
                    Slider(
                        value: Binding(
                            get: { Double(step) },
                            set: { step = Int($0.rounded()); isAutoPlaying = false }
                        ),
                        in: 0...Double(max(totalSteps, 1)),
                        step: 1
                    )
                    .tint(Theme.accent)

                    HStack(spacing: 28) {
                        stepButton("backward.end.fill") { step = 0 }
                        stepButton("chevron.left") { step = max(0, step - 1) }
                        Button {
                            isAutoPlaying.toggle()
                            if isAutoPlaying, step >= totalSteps { step = 0 }
                        } label: {
                            Image(systemName: isAutoPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 46))
                                .foregroundStyle(Theme.accent)
                        }
                        stepButton("chevron.right") { step = min(totalSteps, step + 1) }
                        stepButton("forward.end.fill") { step = totalSteps }
                    }
                    Text("\(step) / \(totalSteps)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isAutoPlaying) {
            guard isAutoPlaying else { return }
            while !Task.isCancelled, step < totalSteps {
                try? await Task.sleep(for: .seconds(0.8))
                guard isAutoPlaying else { return }
                withAnimation(.spring(duration: 0.4)) { step += 1 }
            }
            isAutoPlaying = false
        }
    }

    private var title: String {
        switch match.mode {
        case .local: "Pass & Play"
        case .friend, .ranked, .computer: "vs \(match.opponentName ?? "Opponent")"
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            isAutoPlaying = false
            withAnimation(.spring(duration: 0.35)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.08)))
        }
    }

    private var caption: String {
        guard step > 0 else { return "Initial setup — \(actorName(at: 0)) places first." }
        let action = match.game.actions[step - 1]
        let actor = actorName(at: step - 1)
        switch action {
        case .place(let kind, let position):
            return "\(actor) places a \(kind == .square ? "square" : "round") piece on \(position.notation)"
        case .move(let from, let to):
            return "\(actor) moves \(from.notation) → \(to.notation)"
        case .push(let from, let direction):
            var text = "\(actor) pushes \(directionName(direction)) from \(from.notation)"
            if step == totalSteps, let winner = match.winner {
                text += " — \(playerName(winner)) wins!"
            }
            return text
        }
    }

    /// The player who performed action `index` (state before that action).
    private func actorName(at index: Int) -> String {
        let state = match.game.state(afterActions: index)
        return playerName(state.placingPlayer ?? state.currentPlayer)
    }

    private func playerName(_ player: Player) -> String {
        if let localSide = match.localSide {
            return player == localSide ? "You" : (match.opponentName ?? "Opponent")
        }
        return Theme.playerName(player)
    }

    private func directionName(_ direction: Direction) -> String {
        switch direction {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }
}
