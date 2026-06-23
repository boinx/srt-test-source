#!/usr/bin/env bash
# Start the control server + web dashboard (shows connections, manages caller pushes).
# Requires the streamer to be running first (./start.sh) so the MediaMTX API is up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.env"; [ -f "$CFG" ] || CFG="$DIR/config.env.example"
# shellcheck source=/dev/null
source "$CFG"

command -v python3 >/dev/null || { echo "python3 not found — run: xcode-select --install"; exit 1; }

if ! curl -fsS "http://127.0.0.1:${API_PORT}/v3/paths/list" >/dev/null 2>&1; then
  echo "MediaMTX control API not reachable on :${API_PORT}."
  echo "Start the streamer first:  ./start.sh   (it enables the API)"
  exit 1
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
echo "Dashboard:  http://127.0.0.1:${DASH_PORT}      (open in a browser)"
echo "Streams:    srt://${IP}:${SRT_PORT}?streamid=read:teststream   (and read:pattern)"
echo

export SRT_PORT DASH_PORT
export SRT_READ_PASSPHRASE="${SRT_READ_PASSPHRASE:-}"
export MTX_API="http://127.0.0.1:${API_PORT}"
export PATTERN_WIDTH="${PATTERN_WIDTH:-1280}" PATTERN_HEIGHT="${PATTERN_HEIGHT:-720}"
export PATTERN_FPS="${PATTERN_FPS:-30}" PATTERN_BITRATE="${PATTERN_BITRATE:-3M}"
exec python3 "$DIR/control.py"
