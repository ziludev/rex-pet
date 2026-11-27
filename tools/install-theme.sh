#!/bin/sh
# Installs a theme from Themes/<name>/ into ~/Library/Application Support/rex-pet/Assets/
# by encoding each state's PNG frame sequence into an HEVC-with-alpha .mov so it
# overrides the bundled whale-girl .mov clips.
#
# Usage:
#   tools/install-theme.sh <theme-name>
#   tools/install-theme.sh --restore-default
set -eu
cd "$(dirname "$0")/.."

TARGET_DIR="$HOME/Library/Application Support/rex-pet/Assets"

if [ "${1:-}" = "--restore-default" ]; then
  rm -rf "$TARGET_DIR"
  echo "Restored default bundled pet assets (removed $TARGET_DIR)."
  exit 0
fi

THEME="${1:?usage: tools/install-theme.sh <theme-name> | --restore-default}"
THEME_DIR="Themes/$THEME"
[ -d "$THEME_DIR" ] || { echo "No such theme: $THEME_DIR" >&2; exit 2; }

mkdir -p "$TARGET_DIR"

for STATE in idle working blocked done error; do
  if [ -f "$THEME_DIR/$STATE.mov" ]; then
    echo "Installing $THEME/$STATE.mov -> $TARGET_DIR/$STATE.mov"
    cp "$THEME_DIR/$STATE.mov" "$TARGET_DIR/$STATE.mov"
  elif [ -d "$THEME_DIR/$STATE" ]; then
    WORK="build/tmp"
    ENCODER="$WORK/hevc-alpha-encoder"
    mkdir -p "$WORK"
    if [ ! -x "$ENCODER" ] || [ tools/hevc-alpha-encoder.swift -nt "$ENCODER" ]; then
      echo "Compiling hevc-alpha-encoder..."
      swiftc -O tools/hevc-alpha-encoder.swift -o "$ENCODER"
    fi
    COUNT=$(ls -1 "$THEME_DIR/$STATE"/*.png 2>/dev/null | wc -l | tr -d ' ')
    IN_FPS=12
    [ "$COUNT" -ge 20 ] && IN_FPS=18
    echo "Encoding $THEME/$STATE (${COUNT}f @ ${IN_FPS}fps) -> $TARGET_DIR/$STATE.mov"
    ffmpeg -v error -y -framerate "$IN_FPS" -i "$THEME_DIR/$STATE/%03d.png" \
      -vf "fps=24,format=rgba" -f rawvideo -pix_fmt bgra - \
      | "$ENCODER" "$TARGET_DIR/$STATE.mov" 320 300 24 0.75
  else
    echo "Missing state clip or directory: $THEME_DIR/$STATE" >&2
    exit 2
  fi
done

echo "Installed theme '$THEME' into $TARGET_DIR"
echo "Rex Pet will pick up the new clips on the next state change (or restart the app)."
