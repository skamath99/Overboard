# Overboard! (PushFight iOS)

**Overboard!** is a native iOS app for playing the abstract board game popularized as [Push Fight](https://pushfightgame.com/) with friends, built with SwiftUI and Game Center turn-based matches — **no backend**.

## Features

- **Pass & Play** — full local game on one device, with placement, move/push highlighting, undo, and animated pieces.
- **Play a Friend** — Game Center turn-based match via the system invite UI.
- **Ranked Lobby** — auto-match against strangers from a single global queue, and ratings update after each ranked game.
- **Match History** — every finished game is stored locally and can be replayed move by move (scrubber + autoplay).
- **Elo** — standard Elo (K=32), starting at 1200, persisted locally and mirrored to a Game Center leaderboard (`pushfight.elo`).

## Architecture

```
PushFightiOS/
├── PushFightCore/          Pure Swift rules engine (SPM package, no dependencies)
│   ├── GameState           Board, placement, BFS moves, pushes, rails, anchor, win detection
│   ├── GameRecord          Action log; replay/undo/scrub derive any state
│   └── Elo                 Rating math
├── App/
│   ├── Models/             GameSession (interaction/selection), stores (history, Elo)
│   ├── GameCenter/         GameCenterManager (auth, matchmaking, turn sync), matchmaker UI
│   └── Views/              Home, Game (board + HUD), History, Replay
└── UITests/                Smoke test playing a real game (placement → move → undo → push)
```

`GKTurnBasedMatch.matchData` carries a JSON `OnlineMatchPayload { game: GameRecord, ranked, ratings }` — the action log *is* the game, so sync, replay, and history all share one representation.

## Development

Generate the Xcode project (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)) and run tests:

```sh
xcodegen generate
open PushFight.xcodeproj

cd PushFightCore && swift test          # engine tests
xcodebuild test -project PushFight.xcodeproj -scheme PushFight \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'     # UI smoke test
```

If `swift test` fails with a manifest/linker error, the active toolchain is Command Line Tools; prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or run `sudo xcode-select -s /Applications/Xcode.app`).

### Game Center

Online play requires an app record with the Game Center capability and a leaderboard whose ID matches `EloStore.leaderboardID`. To play online in the simulator/device, sign into Game Center in Settings (sandbox account while in development). Local pass-and-play works with no setup.

## The board

4×8 grid, 26 tiles (a1, g1, h1, a4, b4, h4 are missing). Rails run along the top of row 4 and the bottom of row 1; every other outside edge is open — a piece pushed past an open edge falls off and loses the game for its owner.

```
      abcdefgh
    4   ▢▢▢▢▢    4    ▔ rail
    3 ▢▢▢▢▢▢▢▢ 3
    2 ▢▢▢▢▢▢▢▢ 2
    1  ▢▢▢▢▢    1    ▁ rail
      abcdefgh
```

Each player has 3 squares (move + push) and 2 rounds (move only). A turn is up to 2 moves followed by a mandatory push; the anchor sits on the last pusher and cannot be pushed. Lose by having a piece pushed off — or by being unable to push.
