#!/bin/bash
# Render promo.html to an MP4 (H.264 + AAC, 1080p30) — the version for social media.
#   ./make.sh                 → out/chorus-promo.mp4 (master), -web.mp4 (landing page), -poster.jpg
#   ./make.sh --audio         → re-render only the sound; the picture is re-encoded from the existing frames
# Sound is mastered on the way out: measured, lifted to ~-15 LUFS (social platforms normalise
# around -14), peaks held at -1.5 dBFS by a limiter so they stay under -1 dBTP after AAC.
# Picture: converted with the BT.709 matrix and tagged so (swscale's default is BT.601, which
# players decoding HD as BT.709 show with shifted colour); sRGB transfer, like the PNG frames.
set -euo pipefail
cd "$(dirname "$0")"
NAME="chorus-promo"; AUDIO_ONLY=""
[ "${1:-}" = "--audio" ] && AUDIO_ONLY="--audio-only"
FFMPEG="$(command -v /opt/homebrew/bin/ffmpeg || command -v ffmpeg)"
mkdir -p out
[ out/render -nt render.swift ] || swiftc -O -o out/render render.swift
out/render promo.html "out/$NAME" $AUDIO_ONLY
I=$("$FFMPEG" -hide_banner -i "out/$NAME/audio.wav" -af ebur128 -f null - 2>&1 | awk '/Integrated loudness/{f=1} f && /I:/{print $2; exit}')
GAIN=$(python3 -c "print(round(-15.0 - ($I), 2))")
echo "measured ${I} LUFS → gain ${GAIN} dB"
"$FFMPEG" -y -loglevel error -i "out/$NAME/audio.wav" -af "volume=${GAIN}dB,alimiter=limit=0.841:attack=3:release=60:level=false" "out/$NAME/audio-master.wav"
encode() {   # encode <crf> <x264 preset> <audio bitrate> <output>
  "$FFMPEG" -y -loglevel error -framerate 30 -i "out/$NAME/frames/%05d.png" -i "out/$NAME/audio-master.wav" \
    -vf "scale=out_color_matrix=bt709:out_range=tv" -pix_fmt yuv420p \
    -colorspace bt709 -color_primaries bt709 -color_trc iec61966-2-1 -color_range tv \
    -c:v libx264 -preset "$2" -tune animation -crf "$1" \
    -c:a aac -b:a "$3" -shortest -movflags +faststart "$4"
  echo "→ $4 ($(( $(stat -f %z "$4") / 1024 )) KB)"
}
encode 16 slow 192k "out/$NAME.mp4"               # master, for uploading to social platforms
encode 26 veryslow 128k "out/$NAME-web.mp4"       # landing page: ~3.5 MB, same look at page size
# Poster: t = 10.5 s (frame 315) — all three singing, "Ask once. They all answer." on screen.
"$FFMPEG" -y -loglevel error -i "out/$NAME/frames/00315.png" -q:v 3 "out/$NAME-poster.jpg"
echo "→ out/$NAME-poster.jpg"
