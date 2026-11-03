#!/bin/bash
# Turns a screen recording into a README GIF: trimmed, scaled, at a steady frame rate, with a palette built from the
# clip itself (two passes), so the wheel's gradients and the small text stay sharp at a few MB.
# Usage: scripts/make-gif.sh <recording.mov> <out.gif> [--width 640] [--fps 12] [--start 0] [--duration <s>] [--crop w:h:x:y]
# Needs ffmpeg (brew install ffmpeg). Aim for under 5 MB: shorten the clip, lower --fps or --width if it is bigger.
set -euo pipefail

usage() { sed -n 4p "$0" | sed 's/^# //' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
INPUT="$1"; OUTPUT="$2"; shift 2
WIDTH=640; FPS=12; START=0; DURATION=""; CROP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --width) WIDTH="$2"; shift 2 ;;
        --fps) FPS="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --crop) CROP="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -f "$INPUT" ]] || { echo "No such recording: $INPUT" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "Needs ffmpeg: brew install ffmpeg" >&2; exit 1; }

TRIM=(-ss "$START")
[[ -n "$DURATION" ]] && TRIM+=(-t "$DURATION")
FILTERS="fps=$FPS"
[[ -n "$CROP" ]] && FILTERS="$FILTERS,crop=$CROP"
# Lanczos keeps text legible when a Retina recording is scaled down.
FILTERS="$FILTERS,scale=$WIDTH:-1:flags=lanczos"

PALETTE="$(mktemp -t pomelo-palette).png"
trap 'rm -f "$PALETTE"' EXIT
ffmpeg -v error -y "${TRIM[@]}" -i "$INPUT" -vf "$FILTERS,palettegen=stats_mode=diff" "$PALETTE"
# bayer dithering with a small scale avoids the crawling noise error diffusion gives flat UI backgrounds.
ffmpeg -v error -y "${TRIM[@]}" -i "$INPUT" -i "$PALETTE" \
    -lavfi "$FILTERS [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" -loop 0 "$OUTPUT"

SIZE_KB=$(( $(stat -f %z "$OUTPUT") / 1024 ))
echo "$OUTPUT: ${SIZE_KB} KB"
(( SIZE_KB <= 5120 )) || echo "Over 5 MB: try a shorter --duration, --fps 10 or --width 560." >&2
