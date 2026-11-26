#!/bin/sh
# Turns a green-screen clip (or an existing alpha clip such as a VP9-alpha webm)
# into the HEVC-with-alpha movie Rex Pet plays for one state.
#
#   tools/make-pet.sh working  ~/clip.mp4
#   tools/make-pet.sh idle     dsh-pet/assets/webm/待机呼吸休闲.webm
#
# Defaults: 320x300 at 24 fps, green key 0x00FF00. Override with
# SIZE=… FPS=… KEY=0xRRGGBB PAD=0.06 QUALITY=0.7 CROP=auto|none.
set -eu
cd "$(dirname "$0")/.."

STATE="${1:?usage: make-pet.sh <idle|working|blocked|done|error> <input clip> [outdir]}"
INPUT="${2:?usage: make-pet.sh <state> <input clip> [outdir]}"
OUTDIR="${3:-build/assets}"

SIZE="${SIZE:-320x300}"
FPS="${FPS:-24}"
KEY="${KEY:-0x00FF00}"
PAD="${PAD:-0.06}"
QUALITY="${QUALITY:-0.7}"
CROP="${CROP:-auto}"
W="${SIZE%x*}"
H="${SIZE#*x}"

case "$STATE" in
  idle|working|blocked|done|error) ;;
  *) echo "unknown state: $STATE" >&2; exit 2 ;;
esac
[ -f "$INPUT" ] || { echo "no such clip: $INPUT" >&2; exit 2; }

WORK="build/tmp"
mkdir -p "$WORK" "$OUTDIR"
ENCODER="$WORK/hevc-alpha-encoder"
if [ ! -x "$ENCODER" ] || [ tools/hevc-alpha-encoder.swift -nt "$ENCODER" ]; then
  echo "compiling the encoder"
  swiftc -O tools/hevc-alpha-encoder.swift -o "$ENCODER" 2>/dev/null
fi

# A webm (or any clip that already carries alpha) needs no keying; a green-screen
# source does. Getting this wrong keys the subject's own green pixels away.
HAS_ALPHA=no
DECODE=""
case "$(printf '%s' "$INPUT" | tr 'A-Z' 'a-z')" in
  *.webm)
    HAS_ALPHA=yes
    # ffmpeg's native VP9 decoder drops the alpha plane; libvpx-vp9 keeps it.
    DECODE="-c:v libvpx-vp9"
    ffmpeg -hide_banner -decoders 2>/dev/null | grep -q libvpx-vp9 || {
      echo "this ffmpeg has no libvpx-vp9 decoder, needed to read alpha from webm" >&2; exit 3; }
    ;;
esac

# The subject never fills a 16:9 frame, and a browser-pet clip is framed for a
# window, not for a 320x300 desktop corner: crop to the subject first, then fit.
# The bounding box is the union over sampled frames so the crop never clips a limb.
if [ "$CROP" = auto ]; then
  BOX=$(python3 - "$INPUT" "$PAD" "$DECODE" <<'PY'
import subprocess, sys

path, pad, decode = sys.argv[1], float(sys.argv[2]), sys.argv[3].split()
# Eight spread-out frames are enough: the subject stays put, only its limbs move.
raw = subprocess.run(
    ["ffmpeg", "-v", "error"] + decode + ["-i", path,
     "-vf", "select='not(mod(n,30))'", "-fps_mode", "passthrough",
     "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
    capture_output=True).stdout
if not raw:
    sys.exit(0)

probe = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
    capture_output=True, text=True).stdout.strip().split(",")
w, h = int(probe[0]), int(probe[1])
frame = w * h * 4
count = len(raw) // frame

# Lossy VP9 alpha leaves faint noise across the whole frame, so treat anything
# under 24 as empty; without this the box is always the full frame.
TABLE = bytes(0 if v < 24 else v for v in range(256))
x0, y0, x1, y1 = w, h, 0, 0
for i in range(count):
    alpha = raw[i * frame + 3: (i + 1) * frame: 4]
    for y in range(h):
        row = alpha[y * w:(y + 1) * w].translate(TABLE)
        if not row.strip(b"\0"):
            continue
        first = len(row) - len(row.lstrip(b"\0"))
        last = len(row.rstrip(b"\0")) - 1
        x0, x1 = min(x0, first), max(x1, last)
        y0, y1 = min(y0, y), max(y1, y)
if x1 < x0:
    sys.exit(0)

pad_x, pad_y = int((x1 - x0 + 1) * pad), int((y1 - y0 + 1) * pad)
x0, y0 = max(0, x0 - pad_x), max(0, y0 - pad_y)
x1, y1 = min(w - 1, x1 + pad_x), min(h - 1, y1 + pad_y)
# Even numbers keep the encoder and the scaler happy.
print(f"{max(2, (x1 - x0 + 1) // 2 * 2)}:{max(2, (y1 - y0 + 1) // 2 * 2)}:{x0 // 2 * 2}:{y0 // 2 * 2}")
PY
)
  [ -n "${BOX:-}" ] || { echo "could not find the subject in $INPUT" >&2; exit 3; }
  echo "subject box: $BOX"
  CROPF="crop=$BOX,"
else
  CROPF=""
fi

# Fit inside the target box without stretching, then pad back to an exact size:
# the player is told resizeAspect, so a square-ish frame keeps the pet upright.
FIT="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black@0"

if [ "$HAS_ALPHA" = yes ]; then
  FILTER="${CROPF}${FIT},format=rgba,fps=${FPS}"
else
  FILTER="${CROPF}chromakey=${KEY}:0.12:0.02,${FIT},format=rgba,fps=${FPS}"
  DECODE=""
fi

echo "encoding $STATE from $INPUT"
# shellcheck disable=SC2086
ffmpeg -v error -y $DECODE -i "$INPUT" -vf "$FILTER" -f rawvideo -pix_fmt bgra - \
  | "$ENCODER" "$OUTDIR/$STATE.mov" "$W" "$H" "$FPS" "$QUALITY"

echo "wrote $OUTDIR/$STATE.mov ($(du -h "$OUTDIR/$STATE.mov" | cut -f1))"
