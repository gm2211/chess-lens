#!/bin/bash
# Builds Stockfish 18 (arm64) into mac/vendor/bin/stockfish. The build runs inside safe-run.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd -P)"
SRC="$MAC/vendor/Stockfish"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$MAC/vendor"
  git clone --depth 1 --branch sf_18 https://github.com/official-stockfish/Stockfish "$SRC"
fi
SAFE_RUN="${SAFE_RUN:-$HOME/.claude/bin/safe-run.sh}"
if [ -x "$SAFE_RUN" ]; then
  # --net: the Makefile downloads the NNUE networks.
  "$SAFE_RUN" -C "$SRC" --net -- sh -c "cd src && make -j build ARCH=apple-silicon"
else
  (cd "$SRC/src" && make -j build ARCH=apple-silicon)
fi
mkdir -p "$MAC/vendor/bin"
cp "$SRC/src/stockfish" "$MAC/vendor/bin/stockfish"
# The embedded nets do not load in this build, so ship the net files next to the binary.
cp "$SRC"/src/nn-*.nnue "$MAC/vendor/bin/"
cp "$SRC/Copying.txt" "$MAC/vendor/bin/Copying.txt"
echo "Built $MAC/vendor/bin/stockfish"
