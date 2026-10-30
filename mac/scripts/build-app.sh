#!/bin/bash
# Release build into build/staging, then install to build/ChessLens.app.
# Installs only while the app is not running: replacing a running app's binaries
# makes macOS kill the engine with "Code Signature Invalid".
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# A stale ibtoold that cannot read the project breaks actool ("currentDirectoryPath is unexpectedly nil").
pkill -f "ibtoold --sending-client-environment" 2>/dev/null || true
~/.claude/bin/safe-run.sh -C "$PWD" -- xcodebuild -scheme ChessLens -configuration Release \
  -derivedDataPath build/staging build CODE_SIGN_IDENTITY=- | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
if pgrep -f "build/ChessLens.app/Contents/MacOS/ChessLens" >/dev/null; then
  echo "ChessLens is running; quit it and rerun to install (build is in build/staging)."
  exit 0
fi
rm -rf build/ChessLens.app
cp -R build/staging/Build/Products/Release/ChessLens.app build/ChessLens.app
echo "Installed build/ChessLens.app"
