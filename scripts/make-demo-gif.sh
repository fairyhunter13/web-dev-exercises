#!/usr/bin/env bash
#
# Stitch the two window recordings from `npm run capture` into docs/demo.gif.
#
#   ./scripts/make-demo-gif.sh
#
# Two passes rather than one: a single-pass GIF gets the default 216-colour web
# palette, which posterises the UI's flat greys into bands. Generating a palette
# from the actual frames first keeps them flat.

set -euo pipefail

cd "$(dirname "$0")/.."

VIDEO_DIR="docs/evidence/video"
OUT="docs/demo.gif"
FPS=12
WIDTH=560 # per window; the stacked result is twice this

left=$(find "$VIDEO_DIR/left" -name '*.webm' -print -quit 2>/dev/null || true)
right=$(find "$VIDEO_DIR/right" -name '*.webm' -print -quit 2>/dev/null || true)

if [[ -z "$left" || -z "$right" ]]; then
  echo "No recordings under $VIDEO_DIR. Run 'npm run capture' in chat/frontend first." >&2
  exit 1
fi

filter="[0:v]fps=$FPS,scale=$WIDTH:-2:flags=lanczos[l];
        [1:v]fps=$FPS,scale=$WIDTH:-2:flags=lanczos[r];
        [l][r]hstack=inputs=2[s]"

palette=$(mktemp --suffix=.png)
trap 'rm -f "$palette"' EXIT

ffmpeg -loglevel error -y -i "$left" -i "$right" \
  -filter_complex "$filter;[s]palettegen=stats_mode=diff[p]" -map '[p]' "$palette"

ffmpeg -loglevel error -y -i "$left" -i "$right" -i "$palette" \
  -filter_complex "$filter;[s][2:v]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 "$OUT"

echo "$OUT — $(du -h "$OUT" | cut -f1)"
