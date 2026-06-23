#!/usr/bin/env bash
# Start the SRT test-source streamer: builds the .ts sidecar, renders the MediaMTX
# config from the template, and runs MediaMTX (SRT listener, multi-client fan-out).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.env"; [ -f "$CFG" ] || CFG="$DIR/config.env.example"
# shellcheck source=/dev/null
source "$CFG"
SRT_READ_PASSPHRASE="${SRT_READ_PASSPHRASE:-}"   # tolerate an older config.env without this key

command -v mediamtx >/dev/null || { echo "mediamtx not found — run ./setup.sh first."; exit 1; }
command -v ffmpeg   >/dev/null || { echo "ffmpeg not found — run ./setup.sh first.";   exit 1; }

# Cache dir is intentionally space-free: MediaMTX splits runOnInit on spaces, so the
# .ts input path must contain no spaces (the project folder name may).
CACHE="$HOME/.cache/srt-test-source"
TS="$CACHE/teststream.ts"
GEN="$CACHE/mediamtx.gen.yml"
mkdir -p "$CACHE"

# --- Build the teststream .ts ---
# An .mp4/.mov paces badly under ffmpeg -re; an MPEG-TS stream-copy fixes it while
# preserving the ORIGINAL video + audio. If no source video, generate a test card.
if [ -f "$SRC_VIDEO" ]; then
  if [ ! -f "$TS" ] || [ "$SRC_VIDEO" -nt "$TS" ]; then
    echo "Preparing streaming copy from: $SRC_VIDEO"
    ffmpeg -y -hide_banner -loglevel error -i "$SRC_VIDEO" \
      -map 0:v:0 -map 0:a:0 -c copy -fflags +genpts "$TS"
  fi
else
  if [ ! -f "$TS" ]; then
    echo "No source video at $SRC_VIDEO — generating a test card for 'teststream'."
    echo "(Set SRC_VIDEO in config.env to stream your own clip.)"
    ffmpeg -y -hide_banner -loglevel error \
      -f lavfi -i testsrc2=size=1920x1080:rate=60:duration=20 \
      -f lavfi -i sine=frequency=1000:sample_rate=48000:duration=20 -shortest \
      -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 120 \
      -c:a aac -b:a 128k "$TS"
  fi
fi

# --- Render the MediaMTX config from the template ---
sed -e "s|@TS_PATH@|$TS|g" \
    -e "s|@SRT_PORT@|$SRT_PORT|g" \
    -e "s|@API_PORT@|$API_PORT|g" \
    -e "s|@PATTERN_BITRATE@|$PATTERN_BITRATE|g" \
    -e "s|@READ_PASSPHRASE@|$SRT_READ_PASSPHRASE|g" \
    "$DIR/mediamtx.yml.tmpl" > "$GEN"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
PP_SUFFIX=""; PP_NOTE=""
if [ -n "$SRT_READ_PASSPHRASE" ]; then
  PP_SUFFIX="&passphrase=${SRT_READ_PASSPHRASE}"
  PP_NOTE="  Streams are AES-encrypted — set the SRT passphrase in your receiver:  ${SRT_READ_PASSPHRASE}"
fi
cat <<EOF

  SRT test source  (Listener :$SRT_PORT — fans out to multiple receivers)
  ----------------------------------------------------------------------------
  Add these as an SRT source in mimoLive (Caller mode). Open as many as you like:

     File / test card :  srt://${IP}:${SRT_PORT}?streamid=read:teststream${PP_SUFFIX}
     Synthetic pattern:  srt://${IP}:${SRT_PORT}?streamid=read:pattern${PP_SUFFIX}   (needs ./dashboard.sh)

  If mimoLive only accepts the standard streamid syntax, use instead:
     srt://${IP}:${SRT_PORT}?streamid=#!::m=request,r=teststream${PP_SUFFIX}
${PP_NOTE}
  Dashboard: run ./dashboard.sh in another terminal (http://127.0.0.1:${DASH_PORT})
  Ctrl-C to stop.
  ----------------------------------------------------------------------------

EOF

exec mediamtx "$GEN"
