import SwiftUI
import PushFightCore

extension AILevel {
    var displayName: String {
        switch self {
        case .deckhand: "Deckhand"
        case .bosun: "Bosun"
        case .firstMate: "First Mate"
        case .captain: "Captain"
        }
    }

    var tagline: String {
        switch self {
        case .deckhand: "Plays on instinct. Great for learning the ropes."
        case .bosun: "Grabs what's in front of it, one turn at a time."
        case .firstMate: "Reads your reply before committing."
        case .captain: "Plans turns ahead. Bring your best game."
        }
    }

    var symbolName: String {
        switch self {
        case .deckhand: "sailboat.fill"
        case .bosun: "wind"
        case .firstMate: "binoculars.fill"
        case .captain: "crown.fill"
        }
    }
}

/// Difficulty chooser shown before starting a game against the computer.
struct ComputerLevelPickerView: View {
    let onSelect: (AILevel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                VStack(spacing: 6) {
                    Text("Play the Computer")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("You play Ivory and go first.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack(spacing: 10) {
                    ForEach(AILevel.allCases) { level in
                        Button {
                            onSelect(level)
                        } label: {
                            levelRow(level)
                        }
                        .accessibilityIdentifier(level.displayName)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
    }

    private func levelRow(_ level: AILevel) -> some View {
        HStack(spacing: 14) {
            Image(systemName: level.symbolName)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(level.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(level.tagline)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                )
        )
    }
}
