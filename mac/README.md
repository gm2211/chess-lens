# Étude for macOS

Native SwiftUI version of Étude (macOS 14+, arm64): PGN / FEN / screenshot import, a move tree with
variations, bundled Stockfish 18 analysis and a full-game review.

## Build & run

```sh
mac/scripts/build-stockfish.sh      # clones Stockfish sf_18, builds it inside safe-run, copies binary + NNUE nets to mac/vendor/bin
mac/scripts/fetch-kokoro.sh         # sherpa-onnx static libs (linked into the app) + a dev copy of the Kokoro model (pinned, sha256-checked) into mac/vendor/kokoro
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

## Lesson narration (system voice, Ava, Kokoro)

The app ships with no voice model. Lessons are read by the **best installed English system voice**
(AVSpeechSynthesizer): Premium beats Enhanced beats Standard, then the user's own English variant, then US English, then
Ava (`Packages/VoiceKit`, `SystemVoicePicker`). Novelty and Eloquence voices are never picked. The voice list is re-scanned
whenever the app becomes active, so a voice downloaded in System Settings is used without a restart.

**Apple Premium voices (Ava etc.).** Apple does not let apps download system voices. Settings > Voice lists the installed
English voices grouped by quality, shows "Ava (Premium) is installed" when it is, and otherwise offers "Get Ava (Premium)"
with a button that opens System Settings. It tries `x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent`,
then the legacy `com.apple.preference.universalaccess` pane id (System Settings maps it to the Accessibility extension;
an unknown anchor lands on Accessibility), and spells out the path: Accessibility > Spoken Content > System Voice > Manage Voices.

**Kokoro on demand.** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (Apache-2.0) runs on the CPU inside the
app through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) and onnxruntime, linked statically into the
app binary. Settings > Voice > "Natural voice (Kokoro, ~350 MB download)" downloads the pinned
`kokoro-multi-lang-v1_0.tar.bz2` (URL + SHA-256 in `KokoroAsset.v1_0`) with progress and Cancel, checks the SHA-256,
unpacks only what the voice needs (model.onnx, voices.bin, tokens.txt, the two English lexicons, espeak-ng-data with
only `en_dict`, LICENSE) with `/usr/bin/tar` (a child process inherits the App Sandbox) and moves it into
`~/Library/Containers/app.chesslens.ChessLens/Data/Library/Application Support/Étude/Voices/Kokoro` in one step
(about 378 MB). Failures (offline, HTTP error, checksum mismatch, no space) leave nothing behind and show why. Once
installed, Heart, Bella, Emma and Michael are selectable (Heart is switched to right away) and Settings shows the disk usage and a Remove button.
`KokoroRuntime` also loads a model a developer puts in `Contents/Resources/Kokoro`. If Kokoro is missing or fails to
load, `VoiceNarrator` falls back to the system voice.

Code: `Packages/VoiceKit` (system voice ranking, `KokoroStore`, `KokoroInstaller`; no sherpa dependency, `swift test`
runs on its own), `Packages/KokoroTTS` (C API module, `KokoroEngine`, voices, sentence splitting) and
`ChessLens/Narration` (`VoiceLibrary` = installed voices + download state, `Narrator` protocol, `VoiceNarrator` used by
`LessonPlayer`, `KokoroNarrator` with AVAudioEngine playback, `SystemNarrator` = AVSpeechSynthesizer). Text is cut into
sentences; the first plays while the rest are synthesized, and the player prefetches the current and next step's
narration. The voice is picked in the lesson bar's speaker menu (best system voice + installed Kokoro voices +
"Get More Voices…", which opens Settings > Voice) or in Settings > Voice, and stored in `lesson.voice`
(`system`, `system:<identifier>` or a Kokoro voice id).

```sh
mac/scripts/check-kokoro.sh [model-dir] [voice] [text]   # headless: synthesizes to build/kokoro-check.wav, prints timings and RMS
mac/scripts/check-voice-install-sandbox.sh               # headless: runs the download/verify/unpack path under the App Sandbox
# The install path outside the sandbox, into any folder (then point check-kokoro.sh at <dest>/Kokoro):
(cd mac/Packages/VoiceKit && swift run -c release voice-install ../../vendor/kokoro-dl/kokoro-multi-lang-v1_0.tar.bz2 <dest>)
```

## AI commentary

Settings > AI (`ChessLens/LLM/AIProvidersView.swift`, about 340 pt wide) picks the provider that explains moves. Supported:

| Provider | Sign-in | Notes |
| --- | --- | --- |
| ChatGPT | OAuth (Sign in with ChatGPT) | Plus/Pro plan, via `@byos/chatgpt-local` |
| Claude | OAuth (Claude Pro/Max subscription), loopback + paste-code fallback | Claude subscription sign-in is supported, via `@byos/claude-local` |
| Claude API | pasted key | `claude()` from `@byos/providers` |
| OpenRouter, Groq, Hugging Face | pasted key | `@byos/providers` adapters |
| Grok | SuperGrok device-code sign-in or pasted key | `@byos/grok-local` (tokens + refresh in its own Keychain item); keys stay in the sidecar vault |
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
Update the vendored kit with `~/.claude/bin/safe-run.sh -C . -- node scripts/sync-byos.mjs /path/to/byos <full-40-char-sha>` (runs BYOS's `scripts/vendor.mjs` from that exact commit; entry `chess-lens` in BYOS `consumers.json`); never edit `Sidecar/byos`. Limits: ChatGPT returns the finished text, so its `complete`
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
