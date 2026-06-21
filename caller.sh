#!/usr/bin/env bash
# One-shot caller-mode push of the test video to a remote SRT LISTENER (no dashboard).
# Streams the ORIGINAL video + audio (stream-copy). Use this when mimoLive is set to
# "Listener". For managed/multiple pushes, use ./dashboard.sh + ./callers.sh instead.
#
# Usage:  ./caller.sh <host> [port] [video]
#   ./caller.sh <receiver-ip>            -> srt://<receiver-ip>:9000, default video
#   ./caller.sh <receiver-ip> 9001 /path/to/other.mp4
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.env"; [ -f "$CFG" ] || CFG="$DIR/config.env.example"
# shellcheck source=/dev/null
source "$CFG"

HOST="${1:?Usage: ./caller.sh <host> [port] [video-file]}"
PORT="${2:-9000}"
SRC="${3:-$SRC_VIDEO}"

CACHE="$HOME/.cache/srt-test-source"; mkdir -p "$CACHE"
if [ -f "$SRC" ]; then
  TS="$CACHE/$(basename "${SRC%.*}").caller.ts"
  if [ ! -f "$TS" ] || [ "$SRC" -nt "$TS" ]; then
    echo "Preparing streaming copy: $TS"
    ffmpeg -y -hide_banner -loglevel error -i "$SRC" -map 0:v:0 -map 0:a:0 -c copy -fflags +genpts "$TS"
  fi
elif [ -f "$CACHE/teststream.ts" ]; then
  echo "Source video not found ($SRC) — using the prepared teststream.ts"
  TS="$CACHE/teststream.ts"
else
  echo "No video at $SRC and nothing prepared — run ./start.sh first, or pass a file."; exit 1
fi

echo "Caller -> srt://${HOST}:${PORT}   (looping $(basename "$TS"), original video + audio)"
echo "Ctrl-C to stop."
exec ffmpeg -hide_banner -re -stream_loop -1 -fflags +genpts -i "$TS" \
  -c copy -f mpegts "srt://${HOST}:${PORT}?mode=caller&pkt_size=1316&latency=120"
