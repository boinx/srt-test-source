#!/usr/bin/env bash
# Install/remove an always-on launchd service: starts the streamer + dashboard at
# login and auto-restarts them. Per-user (LaunchAgents), no sudo.
#
#   ./service.sh install
#   ./service.sh uninstall
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA="$HOME/Library/LaunchAgents"
LOG="$HOME/.cache/srt-test-source"
PREFIX="com.boinx.srt-test-source"

# launchd gives services a minimal PATH. ffmpeg may live outside /opt/homebrew/bin
# (e.g. the homebrew-ffmpeg tap puts it in /opt/homebrew/opt/ffmpeg*/bin), so derive
# its real directory now and bake it into the plist — else runOnInit/pattern ffmpeg
# silently fails to launch under the service and no streams appear.
FF_DIR="$(dirname "$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)")"
SVC_PATH="$FF_DIR:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

write_plist(){
  local name="$1" script="$2"
  cat > "$LA/$PREFIX.$name.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PREFIX.$name</string>
  <key>ProgramArguments</key><array><string>$DIR/$script</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG/$name.out.log</string>
  <key>StandardErrorPath</key><string>$LOG/$name.err.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$SVC_PATH</string>
  </dict>
</dict></plist>
EOF
}

case "${1:-}" in
  install)
    mkdir -p "$LA" "$LOG"
    write_plist streamer start.sh
    write_plist dashboard dashboard.sh
    for n in streamer dashboard; do
      launchctl unload "$LA/$PREFIX.$n.plist" 2>/dev/null || true
      launchctl load   "$LA/$PREFIX.$n.plist"
    done
    echo "Installed launchd services (start at login, auto-restart):"
    echo "  $PREFIX.streamer  +  $PREFIX.dashboard"
    echo "Logs: $LOG/*.log     Dashboard: http://127.0.0.1:${DASH_PORT:-8080}"
    ;;
  uninstall)
    for n in streamer dashboard; do
      launchctl unload "$LA/$PREFIX.$n.plist" 2>/dev/null || true
      rm -f "$LA/$PREFIX.$n.plist"
    done
    pkill -f mediamtx.gen.yml 2>/dev/null || true
    pkill -f control.py 2>/dev/null || true
    echo "Removed launchd services."
    ;;
  *)
    echo "Usage: ./service.sh install | uninstall"; exit 1 ;;
esac
