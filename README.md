# PushFight iOS

A native iOS app for playing [Push Fight](https://pushfightgame.com/) with friends, built with SwiftUI and Game Center turn-based matches. Successor to the earlier React Native + Firebase attempt (PushFight / PushFightFirebase / PushFightLibrary), consolidated into this single repo with no backend.

## Architecture

- **`PushFightCore/`** — pure Swift package with the complete rules engine: board geometry, placement, movement (BFS sliding), pushes, rails, the anchor, and both win conditions (piece pushed off; player unable to push). No UI or networking dependencies; fully unit-tested. `GameState` is `Codable` so it serializes directly into `GKTurnBasedMatch.matchData`.
- **App target** (added via Xcode) — SwiftUI board UI. Milestones:
  1. ✅ Rules engine + tests
  2. Pass-and-play on one device
  3. Game Center turn-based multiplayer (invites, turn notifications — no server)
  4. Polish: animations, match history, resign/rematch

## The board

4×8 grid, 26 tiles (a1, g1, h1, a4, b4, h4 are missing). Rails run along the top of row 4 and the bottom of row 1; every other outside edge is open — pieces pushed past an open edge fall off and lose the game for their owner.

```
      abcdefgh
    4   ▢▢▢▢▢    4    ▔ rail
    3 ▢▢▢▢▢▢▢▢ 3
    2 ▢▢▢▢▢▢▢▢ 2
    1  ▢▢▢▢▢    1    ▁ rail
      abcdefgh
```

Each player has 3 squares (move + push) and 2 rounds (move only). A turn is up to 2 moves followed by a mandatory push; the anchor sits on the last pusher and cannot be pushed.

## Development

```sh
cd PushFightCore
swift test
```

If `swift test` fails with a manifest/linker error, the machine's active toolchain is Command Line Tools; use the full Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```
