import SwiftUI
import PushFightCore

/// Rules explainer with small live board illustrations.
struct HowToPlayView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(
                        symbol: "flag.checkered",
                        title: "The Goal",
                        text: "Push any one of your opponent's pieces off the board and you win instantly. The rails along the left and right sides block pushes — pieces can only fall off the open top and bottom ends (and the notched corners)."
                    )

                    section(
                        symbol: "square.on.circle",
                        title: "Your Pieces",
                        text: "Each player has 3 squares and 2 rounds. Squares can move and push. Rounds can only move — but they're just as good at blocking and just as bad to lose."
                    )
                    pieceLegend

                    section(
                        symbol: "square.grid.3x3.topleft.filled",
                        title: "Setup",
                        text: "Before the first turn, each player places all 5 pieces on their half of the board — you at the bottom, your opponent at the top. Any arrangement you like."
                    )

                    section(
                        symbol: "arrow.up.and.down.and.arrow.left.and.right",
                        title: "Your Turn: Move, Then Push",
                        text: "Take up to 2 moves, then you MUST push. A move slides one of your pieces any distance through connected empty tiles — turns are fine, jumping is not. A push shoves the whole line of touching pieces one tile with one of your squares. You can't push an empty tile, and you can't push through a rail."
                    )

                    section(
                        symbol: "anchor",
                        title: "The Anchor",
                        text: "After you push, the anchor lands on your pushing square. An anchored piece cannot be pushed, so your opponent can't simply shove the line straight back. It stays until the next push happens."
                    )
                    if let state = Self.anchorExample {
                        miniBoard(state, caption: "Ivory just pushed upward: the anchor sits on the pusher, freezing that line for Walnut's turn.")
                    }

                    section(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Two Ways to Lose",
                        text: "Lose a piece off the edge, or start what must be a push with no legal push available. Running out of pushes loses the game on the spot — watch your squares' freedom late in the game."
                    )

                    Text("Overboard! is based on the abstract strategy game popularized as Push Fight.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .navigationTitle("How to Play")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pieceLegend: some View {
        HStack(spacing: 24) {
            legendItem(Piece(owner: .one, kind: .square), label: "Square\nmoves + pushes")
            legendItem(Piece(owner: .one, kind: .round), label: "Round\nmoves only")
            legendItem(Piece(owner: .two, kind: .square), label: "Opponent's\npieces")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func legendItem(_ piece: Piece, label: String) -> some View {
        VStack(spacing: 8) {
            PieceView(piece: piece, hasAnchor: false, isSelected: false, size: 40)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private func miniBoard(_ state: GameState, caption: String) -> some View {
        VStack(spacing: 10) {
            BoardView(state: state)
                .frame(maxHeight: 360)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
    }

    /// Mid-game position right after an Ivory push, showing the anchor.
    private static let anchorExample: GameState? = {
        var record = GameRecord()
        let setup: [(String, String)] = [
            ("square", "d2"), ("square", "d3"), ("square", "d1"), ("round", "c2"), ("round", "c3"),
            ("square", "e2"), ("square", "e3"), ("square", "e1"), ("round", "f2"), ("round", "f3"),
        ]
        for (kind, tile) in setup {
            guard let position = Position(tile), let pieceKind = PieceKind(rawValue: kind),
                  (try? record.apply(.place(pieceKind, at: position))) != nil
            else { return nil }
        }
        guard let from = Position("d2"),
              (try? record.apply(.push(from: from, .right))) != nil
        else { return nil }
        return record.state
    }()
}
