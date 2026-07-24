#!/usr/bin/env bash
# Install/uninstall the accio-computer-use daemon as a LaunchAgent.
# The daemon runs with full permissions and forwards tool calls from
# local same-user clients via Unix domain socket.
set -euo pipefail

LABEL="com.accio.computeruse.daemon"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
BINARY_NAME="accio-computer-use"
APP_BUNDLE="/Applications/Accio Computer Use.app"
CANONICAL_BINARY="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
BUNDLE_ID="com.accio.computeruse"
SOCKET_DIR="/tmp/accio-computer-use-$(id -u)"
SOCKET_PATH="$SOCKET_DIR/daemon.sock"
LOG_DIR="$HOME/Library/Logs/AccioComputerUse"

# Find the binary
find_binary() {
  local candidate="${ACCIO_COMPUTER_USE_BINARY:-}"
  if [[ -z "$candidate" ]] && command -v "$BINARY_NAME" &>/dev/null; then
    candidate="$(command -v "$BINARY_NAME")"
  fi
  if [[ ! -x "$CANONICAL_BINARY" || ! -d "$APP_BUNDLE" ]]; then
    return 1
  fi
  if [[ -n "$candidate" && ! "$candidate" -ef "$CANONICAL_BINARY" ]]; then
    echo "Error: refusing non-canonical Accio binary: $candidate" >&2
    return 1
  fi
  local actual_bundle_id
  actual_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$actual_bundle_id" != "$BUNDLE_ID" ]] || ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "Error: canonical Accio app has an invalid bundle identity or signature." >&2
    return 1
  fi
  echo "$CANONICAL_BINARY"
}

install_daemon() {
  local binary
  if ! binary=$(find_binary); then
    echo "Error: canonical $BINARY_NAME not found. Install it first with ./scripts/install-macos.sh"
    exit 1
  fi

  mkdir -p "$PLIST_DIR"
  mkdir -p "$LOG_DIR"

  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary</string>
        <string>serve</string>
        <string>$SOCKET_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
        <key>ACCIO_COMPUTER_USE_VISUAL_CURSOR</key>
        <string>0</string>
    </dict>
</dict>
</plist>
EOF

  echo "Installed LaunchAgent: $PLIST_PATH"

  # Load the daemon
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  echo "Daemon started. Socket: $SOCKET_PATH"
  echo "Logs: $LOG_DIR/daemon.log"
  echo ""
  echo "Important: run 'accio-computer-use setup' first and grant permissions"
  echo "to Accio Computer Use.app. The daemon should use the app-bundled CLI"
  echo "symlink installed by scripts/install-macos.sh."
}

uninstall_daemon() {
  if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$LABEL"
    echo "Daemon stopped."
  fi
  if [[ -f "$PLIST_PATH" ]]; then
    rm "$PLIST_PATH"
    echo "Removed: $PLIST_PATH"
  else
    echo "LaunchAgent not installed."
  fi
  rm -f "$SOCKET_PATH"
  rmdir "$SOCKET_DIR" 2>/dev/null || true
}

status_daemon() {
  if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    echo "Status: running"
    echo "Socket: $SOCKET_PATH"
    if [[ -S "$SOCKET_PATH" ]]; then
      echo "Socket file: exists"
    else
      echo "Socket file: missing (daemon may have just started)"
    fi
  else
    echo "Status: not running"
  fi
}

usage() {
  cat <<'EOF'
Usage: install-daemon.sh [command]

Commands:
  install     Install and start the daemon LaunchAgent (default)
  uninstall   Stop and remove the daemon LaunchAgent
  status      Check if the daemon is running

The daemon listens on /tmp/accio-computer-use-<uid>/daemon.sock and handles
tool calls forwarded from authenticated same-user CLI invocations.
It is a user-session boundary; do not run untrusted code under that account.

Run `accio-computer-use setup` before installing the daemon so permissions are
granted to Accio Computer Use.app, the canonical macOS TCC identity.
EOF
}

case "${1:-install}" in
  install)   install_daemon ;;
  uninstall) uninstall_daemon ;;
  status)    status_daemon ;;
  -h|--help) usage ;;
  *)
    echo "Unknown command: $1"
    usage
    exit 1
    ;;
esac
