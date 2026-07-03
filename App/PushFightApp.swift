import SwiftUI

@main
struct PushFightApp: App {
    @StateObject private var gameCenter: GameCenterManager
    @StateObject private var elo: EloStore
    @StateObject private var history: HistoryStore

    init() {
        let elo = EloStore()
        let history = HistoryStore()
        let gameCenter = GameCenterManager()
        gameCenter.configure(eloStore: elo, historyStore: history)
        _elo = StateObject(wrappedValue: elo)
        _history = StateObject(wrappedValue: history)
        _gameCenter = StateObject(wrappedValue: gameCenter)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .environmentObject(gameCenter)
            .environmentObject(elo)
            .environmentObject(history)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .onAppear {
                gameCenter.authenticate()
            }
        }
    }
}
