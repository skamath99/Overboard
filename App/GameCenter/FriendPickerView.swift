import SwiftUI
import GameKit

/// A shareable party invite, identified by its code.
private struct PartyInvite: Identifiable {
    let code: String
    var id: String { code }

    /// Plain-text Messages blurb; the friend types the code under
    /// "Have a code?".
    var shareText: String {
        "Play me in Overboard! Open Play a Friend → \"Have a code?\" and enter \(code)"
    }
}

/// In-app, theme-matched picker: lists the local player's Game Center friends
/// and recent opponents (one-tap invite each), plus a party-code flow (share
/// the code in Messages, the friend types it under "Have a code?"). Invites
/// flow through `GameCenterManager.open`, so a created match reaches the same
/// lobby/board logic as everything else.
struct FriendPickerView: View {
    @EnvironmentObject private var gameCenter: GameCenterManager
    @Environment(\.dismiss) private var dismiss

    @State private var friends: [GKPlayer] = []
    @State private var recentPlayers: [GKPlayer] = []
    @State private var photos: [String: Image] = [:]
    @State private var isLoading = true
    @State private var loadFailed = false
    /// The player whose direct invite is in flight; blocks further taps so we
    /// never create two matches from a double-tap.
    @State private var invitingID: String?
    @State private var isCreatingInvite = false
    @State private var isJoining = false
    @State private var partyInvite: PartyInvite?
    @State private var showJoinField = false
    @State private var joinCode = ""

    private var isEmpty: Bool { friends.isEmpty && recentPlayers.isEmpty }
    /// Any invite/creation/join in flight — used to disable every actionable row.
    private var isBusy: Bool { invitingID != nil || isCreatingInvite || isJoining }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                // Swap the share step in place rather than presenting a nested
                // sheet: a concurrent sheet presentation races the list and
                // gets cancelled, collapsing the whole picker.
                if let invite = partyInvite {
                    shareStep(invite)
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                }
            }
            .navigationTitle("Play a Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(.white)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(.white)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if isEmpty {
                        Text(loadFailed
                             ? "We couldn't load your Game Center friends. You can still invite someone below."
                             : "No friends or recent players to show yet. Invite someone below.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.bottom, 4)
                    } else {
                        playerSection("FRIENDS", players: friends)
                        playerSection("RECENT PLAYERS", players: recentPlayers)
                    }
                    messagesRow
                    joinRow
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func playerSection(_ title: String, players: [GKPlayer]) -> some View {
        if !players.isEmpty {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.5))
                .kerning(1)
                .padding(.top, 4)
            ForEach(players, id: \.gamePlayerID) { player in
                Button { invite(player) } label: { friendRow(player) }
                    .disabled(isBusy)
            }
        }
    }

    private func friendRow(_ player: GKPlayer) -> some View {
        HStack(spacing: 12) {
            avatar(for: player)
            Text(player.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if invitingID == player.gamePlayerID {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    @ViewBuilder
    private func avatar(for player: GKPlayer) -> some View {
        if let image = photos[player.gamePlayerID] {
            image.resizable().scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(player.displayName.prefix(1))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                )
                .task { await loadPhoto(for: player) }
        }
    }

    // MARK: - Party invite / join rows

    private var messagesRow: some View {
        Button {
            startPartyInvite()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "message.fill")
                    .foregroundStyle(.white.opacity(0.7))
                Text("Invite via Messages…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isCreatingInvite {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
        }
        .disabled(isBusy)
        .padding(.top, isEmpty ? 0 : 8)
    }

    private var joinRow: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.3)) { showJoinField.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "number")
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Have a code? Join a game")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showJoinField ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
            }
            .disabled(isBusy)

            if showJoinField {
                HStack(spacing: 10) {
                    TextField("", text: $joinCode, prompt: Text("ABC123").foregroundColor(.white.opacity(0.3)))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .kerning(2)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                        .onChange(of: joinCode) { _, new in
                            let filtered = String(new.uppercased().prefix(6))
                            if filtered != joinCode { joinCode = filtered }
                        }
                    Button { join() } label: {
                        Group {
                            if isJoining {
                                ProgressView().tint(.white)
                            } else {
                                Text("Join").font(.headline)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.accent)
                        )
                    }
                    .opacity(joinCode.count < 4 || isBusy ? 0.5 : 1)
                    .disabled(joinCode.count < 4 || isBusy)
                }
            }
        }
    }

    private func shareStep(_ invite: PartyInvite) -> some View {
        VStack(spacing: 20) {
            Text("YOUR INVITE CODE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.5))
                .kerning(1)
            Text(invite.code)
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .kerning(4)
            ShareLink(item: invite.shareText) {
                Label("Send in Messages", systemImage: "message.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            Text("The game starts as soon as your friend enters this code under \"Have a code?\".")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadFriends()
        await loadRecentPlayers()
    }

    private func loadFriends() async {
        do {
            // Triggers the friend-list permission prompt on first use.
            let loaded = try await GKLocalPlayer.local.loadFriends()
            friends = loaded.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            loadFailed = true
        }
    }

    /// Recent opponents need no permission, so they fill the common first-run
    /// case where `loadFriends` returns nobody. Drop anyone already listed as a
    /// friend, and the local player.
    private func loadRecentPlayers() async {
        let recent = (try? await GKLocalPlayer.local.loadRecentPlayers()) ?? []
        let friendIDs = Set(friends.map(\.gamePlayerID))
        let localID = GKLocalPlayer.local.gamePlayerID
        recentPlayers = recent
            .filter { !friendIDs.contains($0.gamePlayerID) && $0.gamePlayerID != localID }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private func loadPhoto(for player: GKPlayer) async {
        guard photos[player.gamePlayerID] == nil else { return }
        if let image = try? await player.loadPhoto(for: .small) {
            photos[player.gamePlayerID] = Image(uiImage: image)
        }
    }

    // MARK: - Actions

    private func invite(_ player: GKPlayer) {
        guard !isBusy else { return }
        invitingID = player.gamePlayerID
        Task {
            if await gameCenter.invite(player) {
                dismiss()
            } else {
                // Match wasn't created — stay up so the user can retry.
                invitingID = nil
            }
        }
    }

    private func startPartyInvite() {
        guard !isBusy else { return }
        isCreatingInvite = true
        Task {
            let code = await gameCenter.createPartyInvite()
            isCreatingInvite = false
            if let code {
                withAnimation(.easeInOut(duration: 0.25)) {
                    partyInvite = PartyInvite(code: code)
                }
            }
        }
    }

    private func join() {
        let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !isBusy else { return }
        isJoining = true
        Task {
            await gameCenter.joinParty(code: code)
            dismiss()
        }
    }
}
