#!/usr/bin/env bash
# CLI for the caller-mode pushes, via the control server (control.py / ./dashboard.sh).
#
#   ./callers.sh add <host> [port] [stream] [latency]   # start a push (default port 9000,
#                                                        #   stream teststream, latency 120)
#   ./callers.sh list                                   # show running pushes
#   ./callers.sh rm <id>                                # stop one push
#   ./callers.sh clear                                  # stop all pushes
#
# Examples:
#   ./callers.sh add <receiver-ip> 9000
#   ./callers.sh add <receiver-ip> 9000 pattern 200
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.env"; [ -f "$CFG" ] || CFG="$DIR/config.env.example"
# shellcheck source=/dev/null
source "$CFG"
# Talk to the dashboard on the configured DASH_PORT (override the whole URL with SRT_DASH).
BASE="${SRT_DASH:-http://127.0.0.1:${DASH_PORT}}"

die(){ echo "$1" >&2; exit 1; }
curl -fsS "$BASE/api/status" >/dev/null 2>&1 || die "Control server not reachable at $BASE — run ./dashboard.sh first."

case "${1:-}" in
  add)
    HOST="${2:?usage: ./callers.sh add <host> [port] [stream] [latency]}"
    PORT="${3:-9000}"; STREAM="${4:-teststream}"; LAT="${5:-120}"
    curl -fsS -X POST "$BASE/api/callers" -H 'Content-Type: application/json' \
      -d "{\"host\":\"$HOST\",\"port\":$PORT,\"stream\":\"$STREAM\",\"latency\":$LAT}" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print("started caller id",d.get("id",d))'
    ;;
  list)
    curl -fsS "$BASE/api/status" | python3 -c '
import sys, json
cs = json.load(sys.stdin).get("callers", [])
if not cs:
    print("no caller pushes running"); sys.exit()
print("%3s  %-22s %-12s %8s  %-13s %s" % ("ID","TARGET","STREAM","LATENCY","STATE","RESTARTS"))
for c in cs:
    tgt = "%s:%s" % (c["host"], c["port"])
    print("%3d  %-22s %-12s %6dms  %-13s %d" % (c["id"], tgt, c["stream"], c["latency"], c["state"], c["runs"]))
'
    ;;
  rm)
    ID="${2:?usage: ./callers.sh rm <id>}"
    curl -fsS -X DELETE "$BASE/api/callers/$ID" >/dev/null && echo "stopped caller $ID"
    ;;
  clear)
    curl -fsS -X POST "$BASE/api/callers/stopall" >/dev/null && echo "stopped all caller pushes"
    ;;
  *)
    grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
    ;;
esac
