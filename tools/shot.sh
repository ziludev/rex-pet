#!/bin/bash
# Screenshot the pet window plus a margin: tools/shot.sh [out.png]
set -euo pipefail
out="${1:-/tmp/rex-pet-shot.png}"
bounds=$(swift "$(dirname "$0")/win-bounds.swift" 2>/dev/null || true)
if [ -z "$bounds" ]; then echo "RexPet window not found"; exit 1; fi
read -r x y w h <<<"$bounds"
# CGWindow is top-left origin; screencapture -R uses the same space.
screencapture -x -R "$((x-40)),$((y-40)),$((w+80)),$((h+80))" "$out"
echo "$out"
