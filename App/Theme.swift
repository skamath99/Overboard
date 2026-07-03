import SwiftUI
import PushFightCore

/// Central palette. Dark slate table, ivory vs. walnut pieces, coral anchor.
enum Theme {
    static let background = LinearGradient(
        colors: [Color(hex: 0x1B2233), Color(hex: 0x10141F)],
        startPoint: .top, endPoint: .bottom
    )
    static let boardFrame = Color(hex: 0x2A3247)
    static let tile = Color(hex: 0xE9E2D0)
    static let tileAlt = Color(hex: 0xDDD4BE)
    static let rail = Color(hex: 0x8A93AB)
    static let moveHighlight = Color(hex: 0x4CA3FF)
    static let pushHighlight = Color(hex: 0xFF8A5C)
    static let lastMove = Color(hex: 0xF2C94C)
    static let anchor = Color(hex: 0xE2504C)
    static let accent = Color(hex: 0x4CA3FF)

    static func pieceFill(for player: Player) -> LinearGradient {
        switch player {
        case .one:
            LinearGradient(colors: [Color(hex: 0xFDFBF4), Color(hex: 0xD9D2C0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .two:
            LinearGradient(colors: [Color(hex: 0x6B4A33), Color(hex: 0x3F2A1B)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static func pieceStroke(for player: Player) -> Color {
        player == .one ? Color(hex: 0xB8AF99) : Color(hex: 0x2A1B10)
    }

    static func playerName(_ player: Player) -> String {
        player == .one ? "Ivory" : "Walnut"
    }

    static func playerSwatch(_ player: Player) -> Color {
        player == .one ? Color(hex: 0xEDE6D4) : Color(hex: 0x59402C)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A capsule-shaped primary button used across menus.
struct MenuButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(prominent ? 0 : 0.12))
            )
            .foregroundStyle(prominent ? Color(hex: 0x0D1420) : .white)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
