#!/bin/bash
# Xcode build phase: copies the LLM sidecar (Node runtime + bundle + Keychain addon) into
# Contents/Helpers (sidecar-node, sidecar-keyring.node) and Resources/sidecar.mjs, and signs it so it can run inside the App Sandbox.
set -euo pipefail

SRC="${SRCROOT}/vendor/sidecar"
if [ ! -x "$SRC/node" ] || [ ! -f "$SRC/sidecar.mjs" ]; then
  echo "error: the LLM sidecar is missing at $SRC. Run mac/scripts/build-sidecar.sh first." >&2
  exit 1
fi

CONTENTS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
HELPERS="$CONTENTS/Helpers"
rm -rf "$HELPERS/sidecar" "$CONTENTS/Resources/sidecar.mjs"   # earlier layout
mkdir -p "$HELPERS" "$CONTENTS/Resources"
cp -f "$SRC/node" "$HELPERS/sidecar-node"
cp -f "$SRC/keyring.darwin-arm64.node" "$HELPERS/sidecar-keyring.node"
cp -f "$SRC/sidecar.mjs" "$CONTENTS/Resources/sidecar.mjs"
chmod 755 "$HELPERS/sidecar-node"

# Children of a sandboxed app must carry sandbox + inherit. Node needs JIT; the addon is dlopen()ed, so
# library validation is off (ad-hoc and team-signed addons otherwise fail to load into the hardened node).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$IDENTITY" ] || IDENTITY="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  ENT="${SRCROOT}/ChessLens/Resources/Sidecar.entitlements"
  codesign --force --sign "$IDENTITY" --timestamp=none "$HELPERS/sidecar-keyring.node"
  codesign --force --sign "$IDENTITY" --timestamp=none --options runtime --entitlements "$ENT" "$HELPERS/sidecar-node"
fi
