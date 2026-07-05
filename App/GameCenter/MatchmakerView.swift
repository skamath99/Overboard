import SwiftUI
import GameKit

/// Wraps Game Center's turn-based matchmaker (friend invites + existing
/// games). Found/created matches are delivered through the local player's
/// `GKTurnBasedEventListener`, not this view.
struct MatchmakerView: UIViewControllerRepresentable {
    let request: GKMatchRequest
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> GKTurnBasedMatchmakerViewController {
        let controller = GKTurnBasedMatchmakerViewController(matchRequest: request)
        // Straight to the invite flow — the home screen already lists
        // existing games, and we want the friend picker, not automatch.
        controller.showExistingMatches = false
        controller.matchmakingMode = .inviteOnly
        controller.turnBasedMatchmakerDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: GKTurnBasedMatchmakerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, GKTurnBasedMatchmakerViewControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func turnBasedMatchmakerViewControllerWasCancelled(_ controller: GKTurnBasedMatchmakerViewController) {
            onDismiss()
        }

        func turnBasedMatchmakerViewController(_ controller: GKTurnBasedMatchmakerViewController, didFailWithError error: Error) {
            onDismiss()
        }
    }
}
