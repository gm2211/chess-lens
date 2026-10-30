#!/bin/bash
# Xcode build phase: copies the Stockfish binary into the app bundle (Contents/Helpers/stockfish),
# signs it so it can run inside the App Sandbox, and bundles its GPLv3 licence text.
set -euo pipefail

SRC="${SRCROOT}/vendor/bin/stockfish"
LICENSE="${SRCROOT}/vendor/bin/Copying.txt"
if [ ! -x "$SRC" ]; then
  echo "error: Stockfish is missing at $SRC. Run mac/scripts/build-stockfish.sh first." >&2
  exit 1
fi

CONTENTS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
HELPERS="$CONTENTS/Helpers"
mkdir -p "$HELPERS" "$CONTENTS/Resources"
cp -f "$SRC" "$HELPERS/stockfish"
chmod 755 "$HELPERS/stockfish"
if [ -f "$LICENSE" ]; then
  cp -f "$LICENSE" "$CONTENTS/Resources/Stockfish-Copying.txt"
fi

mkdir -p "$CONTENTS/Resources/Networks"
cp -f "${SRCROOT}"/vendor/bin/nn-*.nnue "$CONTENTS/Resources/Networks/"

# A helper launched from a sandboxed app must carry the sandbox + inherit entitlements.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$IDENTITY" ] || IDENTITY="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
    --entitlements "${SRCROOT}/ChessLens/Resources/Stockfish.entitlements" "$HELPERS/stockfish"
fi
