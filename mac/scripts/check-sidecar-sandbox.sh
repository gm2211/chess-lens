#!/bin/bash
# Headless App Sandbox check for the LLM sidecar. Build the app first (Release or Debug).
#   mac/scripts/check-sidecar-sandbox.sh [path/to/Etude.app]
# It copies the app, replaces its executable with Tools/SidecarSandboxCheck (which drives the real
# LLMSidecar.swift), signs the copy with the app's real entitlements and runs it with a scrubbed
# environment. Nothing is opened on screen. Needs a working Keychain (login session), so it runs outside safe-run;
# the App Sandbox plus `env -i` are what contain the sidecar here.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$MAC/build/dd/Build/Products/Release/Etude.app}"
WORK="${TMPDIR:-/tmp}/etude-sidecar-check"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$APP" "$WORK/Etude.app"
swiftc -O -swift-version 6 -o "$WORK/Etude.app/Contents/MacOS/Etude" \
  "$MAC/Tools/SidecarSandboxCheck/main.swift" "$MAC/ChessLens/LLM/LLMSidecar.swift"
# Same entitlements as the app (read from the built binary so they cannot drift).
codesign -d --entitlements :- "$APP" 2>/dev/null > "$WORK/app.entitlements"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$WORK/app.entitlements" "$WORK/Etude.app"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$WORK/Etude.app/Contents/MacOS/Etude"
