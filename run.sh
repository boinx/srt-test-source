#!/usr/bin/env bash
# Start the streamer + dashboard together (one command). Ctrl-C stops both.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.env"; [ -f "$CFG" ] || CFG="$DIR/config.env.example"
# shellcheck source=/dev/null
source "$CFG"

"$DIR/start.sh" &
cleanup(){ pkill -f "mediamtx.gen.yml" 2>/dev/null || true; pkill -f "streamid=publish" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

for i in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:${API_PORT}/v3/paths/list" >/dev/null 2>&1 && break
  sleep 0.5
done

"$DIR/dashboard.sh"
