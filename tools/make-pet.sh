#!/bin/sh
# Turns a green-screen clip into an HEVC-with-alpha loop the app can play.
#
#   tools/make-pet.sh working clip.mp4        # writes working.mov next to the assets
#
# Drop the result into ~/Library/Application Support/rex-pet/Assets/<state>.mov
# (or Assets/mov/<state>.mov) and the pet plays it instead of drawing itself.
#
# The recipe — green screen, fixed framing, one clip per action — is borrowed
# from PC2005-cloud/dsh-pet (MIT), which builds its pets the same way.
set -eu
cd "$(dirname "$0")/.."
STATE="${1:?usage: tools/make-pet.sh <state> <clip.mp4> [outdir]}"
CLIP="${2:?usage: tools/make-pet.sh <state> <clip.mp4> [outdir]}"
OUTDIR="${3:-build/assets}"
FPS="${FPS:-24}"
SIZE="${SIZE:-320x300}"
KEY="${KEY:-0x00FF00}"

mkdir -p "$OUTDIR" build/tmp
[ -x build/tmp/hevc-alpha-encoder ] || swiftc -O tools/hevc-alpha-encoder.swift -o build/tmp/hevc-alpha-encoder

# Chroma key to RGBA PNG frames: the encoder needs alpha, and ffmpeg is the only
# part that knows how to decode arbitrary containers.
rm -rf build/tmp/frames && mkdir -p build/tmp/frames
ffmpeg -y -loglevel error -i "$CLIP" \
  -vf "chromakey=$KEY:0.12:0.02,scale=$SIZE,fps=$FPS" \
  -pix_fmt rgba "build/tmp/frames/%05d.png"

WIDTH=${SIZE%x*}
HEIGHT=${SIZE#*x}
ffmpeg -y -loglevel error -i "build/tmp/frames/%05d.png" \
  -f rawvideo -pix_fmt bgra - | \
  build/tmp/hevc-alpha-encoder "$OUTDIR/$STATE.mov" "$WIDTH" "$HEIGHT" "$FPS"

echo "wrote $OUTDIR/$STATE.mov"
echo "install: mkdir -p \"$HOME/Library/Application Support/rex-pet/Assets\" && cp \"$OUTDIR/$STATE.mov\" \"$HOME/Library/Application Support/rex-pet/Assets/\""
