#!/bin/bash
# Turns a screen recording into a README GIF that plays like a video: trimmed, scaled, 30 fps, encoded by gifski
# (a palette per frame with temporal dithering), so gradients and small text stay clean where ffmpeg's GIFs band.
# Usage: scripts/make-gif.sh <recording.mov> <out.gif> [--width 960] [--fps 30] [--quality 90] [--start 0] [--duration <s>] [--crop w:h:x:y]
# Needs ffmpeg and gifski (brew install ffmpeg gifski). GitHub shows a GIF kept in the repo at any size, but a
# hero over 10 MB loads slowly: shorten the clip, or lower --width (800) or --fps (24) before --quality.
set -euo pipefail

usage() { sed -n 4p "$0" | sed 's/^# //' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
INPUT="$1"; OUTPUT="$2"; shift 2
WIDTH=960; FPS=30; QUALITY=90; START=0; DURATION=""; CROP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --width) WIDTH="$2"; shift 2 ;;
        --fps) FPS="$2"; shift 2 ;;
        --quality) QUALITY="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --crop) CROP="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -f "$INPUT" ]] || { echo "No such recording: $INPUT" >&2; exit 1; }
for tool in ffmpeg gifski; do
    command -v "$tool" >/dev/null || { echo "Needs $tool: brew install $tool" >&2; exit 1; }
done

TRIM=(-ss "$START")
[[ -n "$DURATION" ]] && TRIM+=(-t "$DURATION")
FILTERS="fps=$FPS"
[[ -n "$CROP" ]] && FILTERS="$FILTERS,crop=$CROP"
# Lanczos keeps text legible when a Retina recording is scaled down.
FILTERS="$FILTERS,scale=$WIDTH:-2:flags=lanczos"

# gifski caps the size at about 800 × 600 unless --width is given, so it is always passed.
ffmpeg -v error "${TRIM[@]}" -i "$INPUT" -vf "$FILTERS" -f yuv4mpegpipe - |
    gifski --quiet --width "$WIDTH" --fps "$FPS" --quality "$QUALITY" --output "$OUTPUT" -

SIZE_KB=$(( $(stat -f %z "$OUTPUT") / 1024 ))
echo "$OUTPUT: ${SIZE_KB} KB"
(( SIZE_KB <= 10240 )) || echo "Over 10 MB: fine for a GIF kept in the repo, slow as a hero. Try --width 800 or --fps 24." >&2
