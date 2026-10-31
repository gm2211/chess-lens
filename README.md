# Chess Lens

A native macOS chess analysis app (SwiftUI, Apple silicon, macOS 14+).

- **Import from a screenshot.** Paste (⌘V) or drop a screenshot of any digital board. An on-device CNN reads the position in about 0.3 s, detects orientation and the last move, and lets you fix any square before loading it.
- **Import PGN / FEN.** Paste text, open `.pgn` files (multi-game files supported), or type a FEN.
- **Stockfish 18.** Bundled native engine with multiple lines, presets (Shallow / Medium / Deep) and advanced settings (depth, lines, threads, hash).
- **Game review.** Accuracy per side, an eval graph, and critical moments that show the refutation the move allowed, the better line, and tactic tags ("hangs the knight on f6", "allows a fork").
- **AI commentary with your own account.** Plain-English explanations of critical moments, grounded in the engine's lines. Pick a provider in Settings > AI: ChatGPT (Plus/Pro sign-in), Claude (Pro/Max subscription sign-in), a Claude API key, OpenRouter, Grok (SuperGrok sign-in or key), Groq, Hugging Face, or Apple Intelligence on-device (macOS 26+). Built on [BYOS](https://github.com/gm2211/byos). Keys and sign-in tokens stay in the macOS Keychain, behind a helper process; the app never sees them.

<!-- demo video goes here -->

## Build

See [mac/README.md](mac/README.md). In short:

```sh
mac/scripts/build-stockfish.sh   # Stockfish 18 + NNUE nets into mac/vendor (gitignored)
mac/scripts/build-sidecar.sh     # bundled Node + BYOS sidecar into mac/vendor/sidecar
mac/scripts/build-app.sh         # Release build -> mac/build/ChessLens.app
```

`web/` holds an earlier browser version (Stockfish WASM); the Mac app is the maintained one.

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)); Stockfish is GPLv3. Third-party piece artwork used for training data and
fixtures is listed with its licenses in [mac/Packages/BoardVision/THIRD_PARTY.md](mac/Packages/BoardVision/THIRD_PARTY.md).
