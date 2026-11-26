#!/bin/sh
# Rebuilds the two pictures the README shows from the clips in Assets/.
# Run it after changing art so the docs cannot drift from what the app plays.
set -eu
cd "$(dirname "$0")/.."

[ -f Assets/idle.mov ] || { echo "no Assets/idle.mov; run tools/make-pet.sh first" >&2; exit 2; }
mkdir -p docs build/tmp

STATES="idle working blocked done error"

# --- states.png: one representative frame per state, side by side ---
i=0
INPUTS=""
for state in $STATES; do
  ffmpeg -v error -y -i "Assets/$state.mov" -vf "select=eq(n\,60)" -frames:v 1 "build/tmp/frame-$i.png"
  INPUTS="$INPUTS -i build/tmp/frame-$i.png"
  i=$((i + 1))
done
# shellcheck disable=SC2086
ffmpeg -v error -y $INPUTS -filter_complex \
  "[0][1][2][3][4]hstack=inputs=5,scale=1300:-1,pad=1300:296:0:14:color=0x16161c" \
  -frames:v 1 docs/states.png

# --- demo.gif: every state in turn, on a dark desktop ---
rm -f build/tmp/list.txt
i=0
for state in $STATES; do
  # One and a half seconds of each, trimmed from the middle of the loop. The
  # segment keeps its alpha (qtrle), otherwise the desktop colour never shows
  # through and every state sits on a black box.
  ffmpeg -v error -y -i "Assets/$state.mov" -ss 1 -t 1.5 -vf "scale=240:-1,fps=10" \
    -an -c:v qtrle -pix_fmt argb "build/tmp/seg-$i.mov"
  echo "file 'seg-$i.mov'" >> build/tmp/list.txt
  i=$((i + 1))
done
# The background needs a duration: an endless lavfi source never reaches EOF, and
# palettegen only emits its frame at EOF.
COMPOSE="-f concat -safe 0 -i build/tmp/list.txt -f lavfi -i color=c=0x16161c:s=240x280:d=8"
GRAPH="[1:v][0:v]overlay=x=(W-w)/2:y=(H-h)/2:format=auto"
# Two passes: the palette has to come from the whole sequence, which one graph
# cannot do because palettegen would re-read the clips.
# shellcheck disable=SC2086
ffmpeg -v error -y $COMPOSE -filter_complex "$GRAPH,palettegen=max_colors=64:stats_mode=full" \
  -frames:v 1 build/tmp/palette.png
# shellcheck disable=SC2086
ffmpeg -v error -y $COMPOSE -i build/tmp/palette.png \
  -filter_complex "$GRAPH[v];[v][2:v]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 docs/demo.gif

ls -lh docs/states.png docs/demo.gif | awk '{print $5, $9}'
