# Étude for macOS

Native SwiftUI version of Étude (macOS 14+, arm64): PGN / FEN / screenshot import, a move tree with
variations, bundled Stockfish 18 analysis and a full-game review.

## Build & run

```sh
mac/scripts/build-stockfish.sh      # clones Stockfish sf_18, builds it inside safe-run, copies binary + NNUE nets to mac/vendor/bin
mac/scripts/build-app.sh            # xcodegen + Release build in safe-run; installs mac/build/Etude.app when the app isn't running
open mac/build/Etude.app
```

Or open `mac/ChessLens.xcodeproj` in Xcode after `xcodegen generate` and press Run. Use `-configuration Release` for the
optimised build (screenshot recognition takes about 0.3 s there; run `swift test -c release` in `Packages/BoardVision` to time it).
The SwiftPM resource bundle `BoardVision_BoardVision.bundle` lands in `Contents/Resources` and loads under the App Sandbox.
Vision OCR is pinned to the CPU, because the Neural Engine compile service is unreachable from the sandbox and blocks forever.

The "Embed Stockfish" build phase (`scripts/embed-stockfish.sh`) copies the engine to `Contents/Helpers/stockfish`,
the nets to `Contents/Resources/Networks`, signs the helper with sandbox + inherit entitlements and bundles
Stockfish's GPLv3 text as `Stockfish-Copying.txt`. The build fails with a pointer to the script if `vendor/bin/stockfish` is missing.
(The nets are shipped as files because the nets embedded in the binary did not load in this build.)

## AI commentary

Settings > AI (`ChessLens/LLM/AIProvidersView.swift`, about 340 pt wide) picks the provider that explains moves. Supported:

| Provider | Sign-in | Notes |
| --- | --- | --- |
| ChatGPT | OAuth (Sign in with ChatGPT) | Plus/Pro plan, via `@byos/chatgpt-local` |
| Claude | OAuth (Claude Pro/Max subscription), loopback + paste-code fallback | Claude subscription sign-in is supported, via `@byos/claude-local` |
| Claude API | pasted key | `claude()` from `@byos/providers` |
| OpenRouter, Groq, Hugging Face | pasted key | `@byos/providers` adapters |
| Grok | SuperGrok device-code sign-in or pasted key | device flow ported from Skim |
| Apple Intelligence | none | on-device FoundationModels, macOS 26+, no sidecar; shows why when unavailable |

Model lists come live from each provider. Keys and tokens live only in the Keychain and only the sidecar touches them.

`Sidecar/` is a small Node program that serves all non-Apple providers. The app launches it as a child process and speaks
newline-delimited JSON on stdin/stdout; every command takes a `provider` (`providers`, `status`, `signIn` with optional
`apiKey`/`mode`, `submitCode`, `signOut`, `complete`; protocol in `Sidecar/src/server.mjs`, adapters in `Sidecar/src/providers.mjs`).
Swift sees account labels, model ids and generated text. Key providers are validated with a model-list call before the key is stored.

```sh
mac/scripts/build-sidecar.sh          # fetches Node 24.22.1 (sha256 + Node.js Foundation signature checked), npm ci, tests, bundles to mac/vendor/sidecar
mac/scripts/check-sidecar-sandbox.sh  # optional: drives the real LLMSidecar.swift under the App Sandbox (no UI, no real sign-in)
mac/scripts/check-play-engine.sh      # optional: drives the real UCIEngine.swift like play mode (games, rapid cancels, restart) beside idle engines
```

The "Embed LLM sidecar" build phase (`scripts/embed-sidecar.sh`) copies `Helpers/sidecar-node` (signed with
`Resources/Sidecar.entitlements`: sandbox + inherit + JIT + no library validation), `Helpers/sidecar-keyring.node` and
`Resources/sidecar.mjs`. The app gains `network.client` and `network.server` (the loopback OAuth callbacks, e.g. Claude's
`localhost:54134`; without it the listener cannot bind). Swift API: `ChessLens/LLM/AIHub.swift` (`AIHub.shared`: `selected`,
`model`, `states`, `refresh(_:)`, `signIn(_:apiKey:paste:)`, `submitCode(_:code:)`, `signOut(_:)`,
`complete(system:prompt:maxTokens:) -> AsyncThrowingStream<String, Error>`), over `LLMSidecar.swift` (the stdio client) and
`AppleIntelligence.swift`. The selected provider and per-provider model are in `UserDefaults` (`ai.provider`, `ai.model.<id>`).
Update the vendored kit with `scripts/vendor.mjs` from a BYOS checkout (`--packages chatgpt-local,claude-local,providers --out mac/Sidecar/byos
--revision mac/Sidecar/byos/BYOS_REVISION`); never edit `Sidecar/byos`. Limits: ChatGPT returns the finished text, so its `complete`
replays it as chunks (the other providers stream live), and `maxTokens` is only a prompt hint except for Claude.

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
