#!/bin/bash
# Builds the LLM sidecar into mac/vendor/sidecar (gitignored), mirroring build-stockfish.sh:
#   node           official Node.js binary (pinned version, sha256 + Developer ID team checked)
#   sidecar.mjs    esbuild bundle of mac/Sidecar/src + the vendored @byos/chatgpt-local, grok-local + jose
#   keyring.darwin-arm64.node   native Keychain addon
# npm runs inside safe-run (lifecycle scripts off); only the Node download uses the network outside npm.
set -euo pipefail

NODE_VERSION="24.22.1"
NODE_SHA256="89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7"
NODE_TEAM="HX7739G8FX"

MAC="$(cd "$(dirname "$0")/.." && pwd)"
SAFE="$HOME/.claude/bin/safe-run.sh"
OUT="$MAC/vendor/sidecar"
mkdir -p "$OUT"

if [ ! -x "$OUT/node" ] || [ "$("$OUT/node" -v 2>/dev/null || true)" != "v$NODE_VERSION" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  TARBALL="node-v$NODE_VERSION-darwin-arm64.tar.gz"
  "$SAFE" -C "$TMP" --net -- curl -fsS -o "$TARBALL" "https://nodejs.org/dist/v$NODE_VERSION/$TARBALL"
  echo "$NODE_SHA256  $TMP/$TARBALL" | shasum -a 256 -c - >/dev/null || { echo "error: Node tarball checksum mismatch" >&2; exit 1; }
  tar -xzf "$TMP/$TARBALL" -C "$TMP" "node-v$NODE_VERSION-darwin-arm64/bin/node"
  codesign -dv "$TMP/node-v$NODE_VERSION-darwin-arm64/bin/node" 2>&1 | grep -q "TeamIdentifier=$NODE_TEAM" \
    || { echo "error: Node binary is not signed by the Node.js Foundation" >&2; exit 1; }
  cp -f "$TMP/node-v$NODE_VERSION-darwin-arm64/bin/node" "$OUT/node"
fi

cd "$MAC/Sidecar"
"$SAFE" -C . --net -- npm ci --no-audit --no-fund
"$SAFE" -C . -- npm test
"$SAFE" -C . -- node build.mjs
cp -f out/sidecar.mjs out/keyring.darwin-arm64.node "$OUT/"
echo "sidecar ready in $OUT"
