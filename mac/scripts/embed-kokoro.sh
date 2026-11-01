#!/bin/bash
# Xcode build phase: copies the Kokoro voice (model, voices, lexicons, espeak-ng-data; mac/vendor/kokoro/model) into
# Contents/Resources/Kokoro. The sherpa-onnx static libraries in vendor/kokoro/lib are linked into the app itself.
set -euo pipefail

SRC="${SRCROOT}/vendor/kokoro"
if [ ! -f "$SRC/model/voices.bin" ] || [ ! -f "$SRC/lib/libsherpa-onnx-c-api.a" ]; then
  echo "error: the Kokoro voice is missing at $SRC. Run mac/scripts/fetch-kokoro.sh first." >&2
  exit 1
fi

DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources/Kokoro"
mkdir -p "$DEST"
rsync -a --delete "$SRC/model/" "$DEST/"
