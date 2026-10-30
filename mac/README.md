# Chess Lens for macOS

Native SwiftUI version of Chess Lens (macOS 14+, arm64): PGN / FEN / screenshot import, a move tree with
variations, bundled Stockfish 18 analysis and a full-game review.

## Build & run

```sh
mac/scripts/build-stockfish.sh      # clones Stockfish sf_18, builds it inside safe-run, copies binary + NNUE nets to mac/vendor/bin
mac/scripts/build-app.sh            # xcodegen + Release build in safe-run; installs mac/build/ChessLens.app when the app isn't running
open mac/build/ChessLens.app
```

Or open `mac/ChessLens.xcodeproj` in Xcode after `xcodegen generate` and press Run. Use `-configuration Release` for the
optimised build (screenshot recognition takes about 0.3 s there; run `swift test -c release` in `Packages/BoardVision` to time it).
The SwiftPM resource bundle `BoardVision_BoardVision.bundle` lands in `Contents/Resources` and loads under the App Sandbox.
Vision OCR is pinned to the CPU, because the Neural Engine compile service is unreachable from the sandbox and blocks forever.

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
