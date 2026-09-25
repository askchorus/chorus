#!/bin/bash
# Render promo.html to an MP4 (H.264 + AAC, 1080p30) — the version for social media.
#   ./make.sh            → out/chorus-promo.mp4
#   ./make.sh sample     → out/sample.mp4 (same thing, different name)
set -euo pipefail
cd "$(dirname "$0")"
NAME="${1:-chorus-promo}"
FFMPEG="$(command -v /opt/homebrew/bin/ffmpeg || command -v ffmpeg)"
mkdir -p out
[ out/render -nt render.swift ] || swiftc -O -o out/render render.swift
out/render promo.html "out/$NAME"
"$FFMPEG" -y -loglevel error -framerate 30 -i "out/$NAME/frames/%05d.png" -i "out/$NAME/audio.wav" \
  -c:v libx264 -preset slow -tune animation -crf 16 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -shortest -movflags +faststart "out/$NAME.mp4"
echo "→ out/$NAME.mp4"
