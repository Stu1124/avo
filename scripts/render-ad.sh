#!/usr/bin/env bash
# Render the 40s Avo launch ad (1920x1080 H.264) from docs/media/ad/index.html.
# Uses the real product shots and mark. Needs Chrome, ffmpeg, and Node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${AVO_AD_WORKDIR:-/tmp/avo-ad-render}"
TOOLS="${AVO_AD_TOOLS:-/tmp/avo-ad-tools}"
CHROME="${CHROME:-/usr/local/bin/google-chrome}"
OUT="${1:-$ROOT/docs/media/avo-ad.mp4}"

cd "$ROOT"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/fonts" "$TOOLS"

cp "$ROOT/docs/media/ad/index.html" "$WORKDIR/"
cp "$ROOT/docs/media/onboarding.jpg" "$WORKDIR/"
cp "$ROOT/docs/media/confirm-card.png" "$WORKDIR/"
cp "$ROOT/docs/media/notch-answer.png" "$WORKDIR/"
cp "$ROOT/docs/media/coding-tasks.png" "$WORKDIR/"
cp "$ROOT/design/avo-icon.svg" "$WORKDIR/"
cp /usr/share/fonts/truetype/macos/Inter-Regular.ttf "$WORKDIR/fonts/"
cp /usr/share/fonts/truetype/macos/Inter-Medium.ttf "$WORKDIR/fonts/"
cp /usr/share/fonts/truetype/macos/Inter-SemiBold.ttf "$WORKDIR/fonts/"
cp /usr/share/fonts/truetype/macos/Inter-Bold.ttf "$WORKDIR/fonts/"

python3 "$ROOT/docs/media/ad/score.py" "$WORKDIR/score.wav"

fuser -k 8765/tcp >/dev/null 2>&1 || true
PORT=8765
python3 -m http.server "$PORT" --directory "$WORKDIR" --bind 127.0.0.1 >/tmp/avo-ad-http.log 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8; do
  if curl -sf "http://127.0.0.1:$PORT/index.html" >/dev/null; then
    break
  fi
  sleep 0.25
done
curl -sf "http://127.0.0.1:$PORT/index.html" >/dev/null

if [[ ! -d "$TOOLS/node_modules/playwright-core" ]]; then
  (
    cd "$TOOLS"
    npm init -y >/dev/null
    npm install --silent playwright-core@1.55.0
  )
fi

cp "$ROOT/docs/media/ad/record.mjs" "$TOOLS/record.mjs"
(
  cd "$TOOLS"
  node record.mjs "http://127.0.0.1:$PORT/index.html" "$WORKDIR/frames" "$CHROME"
)

mkdir -p "$(dirname "$OUT")"
ffmpeg -y -framerate 30 -i "$WORKDIR/frames/f%05d.jpg" -i "$WORKDIR/score.wav" \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -shortest \
  -movflags +faststart \
  "$OUT" >/tmp/avo-ad-ffmpeg.log 2>&1

echo "$OUT"
