import SwiftUI
import PushFightCore

/// Renders the board, pieces, rails, anchor, and interaction highlights.
/// Pure function of its inputs; interaction is reported through `onTap`.
///
/// Drawn in portrait, chess-style: player one's half (columns a–d) is at the
/// bottom and their pieces advance upward. Engine columns map to screen rows
/// (a at the bottom) and engine rows map to screen columns, so the rails run
/// down the left (rank 1) and right (rank 4) sides and pieces are pushed off
/// the top and bottom ends.
struct BoardView: View {
    let state: GameState
    var tracker: PieceTracker?
    var selection: Position?
    var moveTargets: Set<Position> = []
    var pushTargets: Set<Position> = []
    var placementTargets: Set<Position> = []
    /// The player seated at the bottom of the screen. Online games pass the
    /// local side so each player sees their own pieces advancing upward.
    var perspective: Player = .one
    var onTap: ((Position) -> Void)?

    private static let railSpans: [(row: Int, columns: ClosedRange<Int>, outward: Bool)] = [
        (row: 3, columns: 2...6, outward: true),   // beside c4–g4 → right side
        (row: 0, columns: 1...5, outward: false),  // beside b1–f1 → left side
    ]

    var body: some View {
        GeometryReader { proxy in
            let tile = min(proxy.size.width / 5.6, proxy.size.height / 8.8)
            let boardWidth = tile * 4
            let boardHeight = tile * 8
            let originX = (proxy.size.width - boardWidth) / 2
            let originY = (proxy.size.height - boardHeight) / 2

            ZStack {
                boardFrame(tile: tile)
                    .frame(width: boardWidth + tile * 0.9, height: boardHeight + tile * 0.5)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                ForEach(Board.allTiles, id: \.self) { position in
                    tileView(position, size: tile)
                        .position(center(of: position, tile: tile, originX: originX, originY: originY))
                }

                ForEach(Self.railSpans, id: \.row) { span in
                    railBar(span: span, tile: tile, originX: originX, originY: originY)
                }

                ForEach(sortedPieces, id: \.id) { item in
                    PieceView(
                        piece: item.piece,
                        hasAnchor: state.anchor == item.position,
                        isSelected: selection == item.position,
                        size: tile * 0.74
                    )
                    .position(center(of: item.position, tile: tile, originX: originX, originY: originY))
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .aspectRatio(5.6 / 8.8, contentMode: .fit)
    }

    /// Pieces with stable identities so SwiftUI animates slides and pushes.
    /// Without a tracker, identity falls back to the tile itself.
    private var sortedPieces: [(id: Int, position: Position, piece: Piece)] {
        state.pieces
            .map { entry in
                (id: tracker?.ids[entry.key] ?? (1000 + entry.key.column * Board.rowCount + entry.key.row),
                 position: entry.key,
                 piece: entry.value)
            }
            .sorted { $0.id < $1.id }
    }

    /// Maps an engine position to display coordinates in tile units,
    /// honouring the perspective (a 180° turn for player two).
    private func displayXY(_ position: Position) -> (x: CGFloat, y: CGFloat) {
        perspective == .one
            ? (CGFloat(position.row), CGFloat(Board.columnCount - 1 - position.column))
            : (CGFloat(Board.rowCount - 1 - position.row), CGFloat(position.column))
    }

    private func center(of position: Position, tile: CGFloat, originX: CGFloat, originY: CGFloat) -> CGPoint {
        let (x, y) = displayXY(position)
        return CGPoint(
            x: originX + (x + 0.5) * tile,
            y: originY + (y + 0.5) * tile
        )
    }

    private func boardFrame(tile: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous)
            .fill(Theme.boardFrame)
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    @ViewBuilder
    private func tileView(_ position: Position, size: CGFloat) -> some View {
        let highlight = highlightKind(for: position)
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill((position.column + position.row).isMultiple(of: 2) ? Theme.tile : Theme.tileAlt)
            .overlay {
                if let highlight {
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .fill(highlight.opacity(0.34))
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(highlight, lineWidth: 2.5)
                }
            }
            .frame(width: size * 0.92, height: size * 0.92)
            .contentShape(Rectangle())
            .onTapGesture { onTap?(position) }
            .accessibilityElement()
            .accessibilityIdentifier("tile-\(position.notation)")
            .accessibilityAddTraits(.isButton)
    }

    private func highlightKind(for position: Position) -> Color? {
        if pushTargets.contains(position) { return Theme.pushHighlight }
        if moveTargets.contains(position) { return Theme.moveHighlight }
        if placementTargets.contains(position) { return Theme.moveHighlight }
        if selection == position { return Theme.lastMove }
        return nil
    }

    private func railBar(span: (row: Int, columns: ClosedRange<Int>, outward: Bool), tile: CGFloat, originX: CGFloat, originY: CGFloat) -> some View {
        let length = tile * CGFloat(span.columns.count)
        let start = displayXY(Position(column: span.columns.lowerBound, row: span.row))
        let end = displayXY(Position(column: span.columns.upperBound, row: span.row))
        let towardOutside: CGFloat = (span.outward != (perspective == .two)) ? 1 : -1
        return Capsule()
            .fill(Theme.rail)
            .frame(width: tile * 0.13, height: length * 0.98)
            .position(
                x: originX + (start.x + 0.5) * tile + towardOutside * tile * 0.58,
                y: originY + ((start.y + end.y) / 2 + 0.5) * tile
            )
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// A single game piece: rounded square or circle, with anchor badge.
struct PieceView: View {
    let piece: Piece
    let hasAnchor: Bool
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            shape
                .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.06)
            if hasAnchor {
                Image(systemName: "anchor")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.1)
                    .background(Circle().fill(Theme.anchor))
                    .offset(x: size * 0.32, y: -size * 0.32)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(isSelected ? 1.12 : 1)
        .animation(.spring(duration: 0.25), value: isSelected)
    }

    @ViewBuilder
    private var shape: some View {
        let stroke = Theme.pieceStroke(for: piece.owner)
        switch piece.kind {
        case .square:
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.pieceFill(for: piece.owner))
                .strokeBorder(stroke, lineWidth: size * 0.05)
        case .round:
            Circle()
                .fill(Theme.pieceFill(for: piece.owner))
                .strokeBorder(stroke, lineWidth: size * 0.05)
        }
    }
}
