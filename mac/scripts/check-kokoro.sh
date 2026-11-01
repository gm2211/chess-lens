#!/bin/bash
# Headless check of the Kokoro voice: builds Packages/KokoroTTS's kokoro-check (linked against mac/vendor/kokoro/lib)
# and synthesizes a sentence to build/kokoro-check.wav, printing load time, time to first audio, duration and RMS.
# Nothing is played. Runs inside safe-run.
#   mac/scripts/check-kokoro.sh [model-dir] [voice] [text]
# model-dir defaults to the app bundle's copy (build/Etude.app/Contents/Resources/Kokoro), else vendor/kokoro/model.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd -P)"
DIR="${1:-}"
if [ -z "$DIR" ]; then
  DIR="$MAC/build/Etude.app/Contents/Resources/Kokoro"
  [ -d "$DIR" ] || DIR="$MAC/vendor/kokoro/model"
fi
if [ ! -f "$MAC/vendor/kokoro/lib/libsherpa-onnx-c-api.a" ]; then
  echo "error: Kokoro is missing at $MAC/vendor/kokoro. Run mac/scripts/fetch-kokoro.sh first." >&2
  exit 1
fi
mkdir -p "$MAC/build"
~/.claude/bin/safe-run.sh -C "$MAC" --xcode ${KOKORO_THREADS:+--env KOKORO_THREADS} ${KOKORO_DEBUG:+--env KOKORO_DEBUG} -- bash -c '
  set -euo pipefail
  cd "$1/Packages/KokoroTTS"
  swift build --disable-sandbox -c release --product kokoro-check -Xlinker -L"$1/vendor/kokoro/lib" 2>&1 | grep -E "error|warning: .*Kokoro" || true
  BIN="$(swift build --disable-sandbox -c release --show-bin-path)/kokoro-check"
  shift
  "$BIN" "$@"
' _ "$MAC" "$DIR" "$MAC/build/kokoro-check.wav" ${2:+"$2"} ${3:+"$3"}
