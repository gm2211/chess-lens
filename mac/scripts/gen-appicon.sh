#!/bin/bash
# Regenerates every AppIcon size from the 1024 master (ChessLens/Resources/AppIcon-1024.png).
# The master already has the macOS icon grid baked in (824 px squircle, transparent margin).
set -euo pipefail
cd "$(dirname "$0")/.."
MASTER=ChessLens/Resources/AppIcon-1024.png
SET=ChessLens/Resources/Assets.xcassets/AppIcon.appiconset
for base in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((base * scale)); suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    magick "$MASTER" -filter Lanczos -resize "${px}x${px}" "PNG32:$SET/icon_${base}x${base}${suffix}.png"
  done
done
