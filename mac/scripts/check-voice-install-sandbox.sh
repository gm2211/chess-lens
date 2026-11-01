#!/bin/bash
# Headless App Sandbox check for the on-demand Kokoro download. Build the app first (scripts/build-app.sh) and have
# the archive in vendor/kokoro-dl (scripts/fetch-kokoro.sh puts it there).
#   mac/scripts/check-voice-install-sandbox.sh [path/to/Etude.app]
# Serves the archive on 127.0.0.1 (python http.server inside safe-run), copies the app, replaces its executable with
# Tools/VoiceInstallSandboxCheck (which drives the real Packages/VoiceKit installer), signs the copy with the app's
# entitlements and runs it with a scrubbed environment: URLSession download with progress, SHA-256 check and the
# /usr/bin/tar child process all run under the App Sandbox. It installs into the container's tmp and removes it.
# Nothing is opened on screen and nothing is played.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="${1:-$MAC/build/Etude.app}"
ARCHIVE="$MAC/vendor/kokoro-dl/kokoro-multi-lang-v1_0.tar.bz2"
[ -f "$ARCHIVE" ] || { echo "error: $ARCHIVE is missing; run scripts/fetch-kokoro.sh" >&2; exit 1; }
WORK="${TMPDIR:-/tmp}/etude-voice-check"
PORT="${PORT:-8765}"
rm -rf "$WORK"; mkdir -p "$WORK"

~/.claude/bin/safe-run.sh -C "$MAC" -- python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$MAC/vendor/kokoro-dl" >"$WORK/http.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; pkill -f "http.server $PORT" 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sfI "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.2; done

cp -R "$APP" "$WORK/Etude.app"
swiftc -O -swift-version 6 -o "$WORK/Etude.app/Contents/MacOS/Etude" \
  "$MAC/Tools/VoiceInstallSandboxCheck/main.swift" "$MAC"/Packages/VoiceKit/Sources/VoiceKit/*.swift 2>&1 | grep -v "^$" || true
codesign -d --entitlements :- "$APP" 2>/dev/null > "$WORK/app.entitlements"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$WORK/app.entitlements" "$WORK/Etude.app"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$WORK/Etude.app/Contents/MacOS/Etude" "http://127.0.0.1:$PORT/$(basename "$ARCHIVE")"
