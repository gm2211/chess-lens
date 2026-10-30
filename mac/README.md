# Chess Lens for macOS

Native SwiftUI version of Chess Lens (macOS 14+, arm64): PGN / FEN / screenshot import, a move tree with
variations, bundled Stockfish 18 analysis and a full-game review.

## Build

```sh
mac/scripts/build-stockfish.sh      # clones Stockfish sf_18, builds it inside safe-run, copies binary + NNUE nets to mac/vendor/bin
cd mac && xcodegen generate         # the .xcodeproj is gitignored; regenerate it any time
~/.claude/bin/safe-run.sh -C mac -- xcodebuild -project ChessLens.xcodeproj -scheme ChessLens \
    -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY=-
open mac/build/Build/Products/Debug/ChessLens.app
```

The "Embed Stockfish" build phase (`scripts/embed-stockfish.sh`) copies the engine to `Contents/Helpers/stockfish`,
the nets to `Contents/Resources/Networks`, signs the helper with sandbox + inherit entitlements and bundles
Stockfish's GPLv3 text as `Stockfish-Copying.txt`. The build fails with a pointer to the script if `vendor/bin/stockfish` is missing.
(The nets are shipped as files because the nets embedded in the binary did not load in this build.)

## Layout

- `Packages/ChessCore` rules, FEN, SAN, PGN (variations, comments, NAGs), UCI parsing. `swift test` in that folder
  (perft: start 197281 at depth 4, Kiwipete 97862 at depth 3, plus en passant, castling, promotion).
- `Packages/BoardVision` screenshot recognition (separate work; the app only uses `BoardRecognizer`).
- `ChessLens/Engine` `UCIEngine` actor (Process + pipes, stop/drain sequencing), `EngineController`.
- `ChessLens/Model` app state, review/classification, import state. `ChessLens/Views` SwiftUI.
- `scripts/gen-assets.py` regenerates the asset catalog (cburnett pieces and the colour tokens) from `web/index.html`.

Fonts: system fonts (New York for display, SF, SF Mono) instead of the web's Google fonts.
App Sandbox is on; the only entitlement beyond it is read access to user-selected files.
Paste (Cmd+V) works anywhere in the window; "Paste Game or Position" (Shift+Cmd+V) is the menu equivalent.
