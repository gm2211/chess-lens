#!/bin/bash
# Headless check that the play-mode engine never gets stuck "thinking".
#   mac/scripts/check-play-engine.sh [games] [think-ms] [idle-engines]
# Compiles Tools/PlayEngineCheck with the real UCIEngine.swift and ChessCore, then plays games and rapid
# cancel/search sequences against mac/vendor/bin/stockfish (the app's copy only runs inside the app sandbox).
# Runs its build and the engine through safe-run. Nothing is opened on screen.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$MAC/build/play-engine-check"
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/run.sh" <<SH
set -euo pipefail
cd "$WORK"
swiftc -O -swift-version 6 -parse-as-library -emit-library -static -emit-module -module-name ChessCore \
  -o libChessCore.a "$MAC"/Packages/ChessCore/Sources/ChessCore/*.swift
swiftc -O -swift-version 6 -I . -L . -lChessCore -o play-engine-check \
  "$MAC/Tools/PlayEngineCheck/main.swift" "$MAC/ChessLens/Engine/UCIEngine.swift"
./play-engine-check "$MAC/vendor/bin/stockfish" ${1:-3} ${2:-200} ${3:-2}
SH
~/.claude/bin/safe-run.sh -C "$MAC" --xcode -- bash "$WORK/run.sh"
