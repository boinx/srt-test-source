#!/usr/bin/env bash
# One-time setup for the SRT test source on macOS (Apple Silicon).
# Installs/checks dependencies, then you run ./run.sh.
#
#   ./setup.sh             # install + check dependencies
#   ./setup.sh --service   # also install the always-on launchd service (start at login)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say(){ printf "\n\033[1m%s\033[0m\n" "$*"; }

[ "$(uname)" = "Darwin" ] || { echo "This tool is macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || echo "Note: built/tested on Apple Silicon; Intel may work but is untested."

say "1/5  Homebrew"
if ! command -v brew >/dev/null; then
  echo "Homebrew is required. Install it from https://brew.sh then re-run ./setup.sh"; exit 1
fi
echo "ok: $(brew --version | head -1)"

say "2/5  mediamtx"
if command -v mediamtx >/dev/null; then echo "ok: $(mediamtx --version 2>/dev/null | head -1)"
else brew install mediamtx; fi

say "3/5  ffmpeg (must include libsrt)"
have_srt(){ command -v ffmpeg >/dev/null && ffmpeg -hide_banner -buildconf 2>/dev/null | grep -q -- "--enable-libsrt"; }
if have_srt; then
  echo "ok: ffmpeg with libsrt ($(ffmpeg -version | head -1 | awk '{print $3}'))"
else
  echo "ffmpeg is missing or lacks libsrt. Installing a build with SRT..."
  echo "(plain 'brew install ffmpeg' dropped libsrt in 8.1.x — using the homebrew-ffmpeg tap)"
  brew tap homebrew-ffmpeg/ffmpeg 2>/dev/null || true
  brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-srt || brew install ffmpeg || true
  if ! have_srt; then
    echo
    echo "ERROR: ffmpeg still has no libsrt. Install manually, e.g.:"
    echo "  brew tap homebrew-ffmpeg/ffmpeg && brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-srt"
    echo "then verify:  ffmpeg -buildconf | grep libsrt"
    exit 1
  fi
  echo "ok: ffmpeg with libsrt installed"
fi
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox \
  && echo "ok: h264_videotoolbox hardware encoder available" \
  || echo "note: h264_videotoolbox not found — the 'pattern' stream will be slower."

say "4/5  python3 (for the dashboard)"
if command -v python3 >/dev/null; then echo "ok: $(python3 --version)"
else echo "python3 not found. Install the Command Line Tools:  xcode-select --install"; exit 1; fi

say "5/5  scripts + local config"
chmod +x "$DIR"/*.sh "$DIR/control.py"
if [ ! -f "$DIR/config.env" ]; then
  cp "$DIR/config.env.example" "$DIR/config.env"
  echo "created config.env — edit it to set SRC_VIDEO (otherwise a test card is used)."
else
  echo "config.env already present"
fi

if [ "${1:-}" = "--service" ]; then
  "$DIR/service.sh" install
fi

cat <<EOF

Setup complete.

  Start everything:   ./run.sh         (streamer + dashboard)
  Or separately:      ./start.sh   and   ./dashboard.sh
  Dashboard:          http://127.0.0.1:${DASH_PORT:-8080}

Edit config.env to point SRC_VIDEO at your own clip (otherwise a test card is used).
EOF
