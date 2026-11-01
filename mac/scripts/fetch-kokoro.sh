#!/bin/bash
# Fetches the Kokoro-82M neural voice used for lesson narration into mac/vendor/kokoro (gitignored):
#   lib/    sherpa-onnx v1.13.8 static libraries for macOS arm64 (C API + onnxruntime + espeak-ng), linked into the app
#   model/  for development and scripts/check-kokoro.sh only (the app downloads it on demand, Packages/VoiceKit):
#           kokoro-multi-lang-v1_0: fp32 model (int8 is 3x smaller but slower than real time on Apple Silicon), voices, tokens, English lexicons, espeak-ng-data (English only)
# The archive stays in vendor/kokoro-dl for scripts/check-voice-install-sandbox.sh.
# Downloads run inside safe-run with --net; every archive is checked against a pinned SHA-256 before it is unpacked.
set -euo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$MAC/vendor/kokoro"
DL="$MAC/vendor/kokoro-dl"

SHERPA_VERSION=1.13.8
SHERPA_NAME="sherpa-onnx-v$SHERPA_VERSION-osx-arm64-static-lib"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/$SHERPA_NAME.tar.bz2"
SHERPA_SHA256=9091bf160dc7fdacedbc906b212badf53c2993f4e5277a0e03998e96c31d60da

MODEL_NAME=kokoro-multi-lang-v1_0
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$MODEL_NAME.tar.bz2"
MODEL_SHA256=60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4

SAFE_RUN="${SAFE_RUN:-$HOME/.claude/bin/safe-run.sh}"
mkdir -p "$DL"

fetch() { # url sha256
  local file="$DL/$(basename "$1")"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$2" ]; then return; fi
  rm -f "$file"
  echo "Downloading $1"
  if [ -x "$SAFE_RUN" ]; then
    "$SAFE_RUN" -C "$MAC" --net -- curl -fL --retry 3 -o "$file" "$1"
  else
    curl -fL --retry 3 -o "$file" "$1"
  fi
  local got; got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    rm -f "$file"
    echo "error: checksum mismatch for $(basename "$1"): expected $2, got $got" >&2
    exit 1
  fi
}

fetch "$SHERPA_URL" "$SHERPA_SHA256"
fetch "$MODEL_URL" "$MODEL_SHA256"

STAGE="$DL/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
tar -xjf "$DL/$SHERPA_NAME.tar.bz2" -C "$STAGE"
tar -xjf "$DL/$MODEL_NAME.tar.bz2" -C "$STAGE"

rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/model"
# Only what the TTS C API needs (no portaudio / C++ API).
for l in sherpa-onnx-c-api sherpa-onnx-core onnxruntime espeak-ng piper_phonemize ucd kaldi-native-fbank-core \
         kaldi-decoder-core kissfft-float sherpa-onnx-fst sherpa-onnx-fstfar sherpa-onnx-kaldifst-core ssentencepiece_core; do
  cp "$STAGE/$SHERPA_NAME/lib/lib$l.a" "$OUT/lib/"
done

M="$STAGE/$MODEL_NAME"
cp "$M/model.onnx" "$M/voices.bin" "$M/tokens.txt" "$M/lexicon-us-en.txt" "$M/lexicon-gb-en.txt" "$OUT/model/"
cp "$M/LICENSE" "$OUT/model/Kokoro-LICENSE.txt"
cp -R "$M/espeak-ng-data" "$OUT/model/espeak-ng-data"
# English narration only: drop the other languages' pronunciation dictionaries (about 15 MB).
find "$OUT/model/espeak-ng-data" -maxdepth 1 -name '*_dict' ! -name 'en_dict' -delete
rm -rf "$STAGE"

echo "$SHERPA_NAME + $MODEL_NAME" > "$OUT/VERSION"
echo "Kokoro ready in $OUT ($(du -sh "$OUT/model" | cut -f1) model, $(du -sh "$OUT/lib" | cut -f1) libraries)"
