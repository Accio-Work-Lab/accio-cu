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

daemon_is_healthy() {
  if [[ -x "$CANONICAL_BINARY" ]] &&
     "$CANONICAL_BINARY" help daemon-status 2>/dev/null |
       grep -q "accio-computer-use daemon-status"; then
    "$CANONICAL_BINARY" daemon-status "$SOCKET_PATH" >/dev/null 2>&1
    return
  fi

  # Compatibility probe for an older installed binary while this newer
  # installer script is being used during an upgrade.
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$SOCKET_PATH" <<'PY'
import os
import socket
import stat
import sys

path = sys.argv[1]
try:
    metadata = os.lstat(path)
    if (
        metadata.st_uid != os.getuid()
        or not stat.S_ISSOCK(metadata.st_mode)
        or metadata.st_mode & 0o077
    ):
        raise OSError("unsafe daemon socket")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(0.5)
        connection.connect(path)
        if hasattr(connection, "getpeereid"):
            peer_uid, _ = connection.getpeereid()
            if peer_uid != os.getuid():
                raise OSError("daemon peer belongs to another user")
    finally:
        connection.close()
except OSError:
    raise SystemExit(1)
PY
}

wait_for_daemon_health() {
  local attempt
  for attempt in {1..20}; do
    if daemon_is_healthy; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

launch_agent_last_exit_code() {
  local launch_state
  launch_state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)" || return 1
  printf '%s\n' "$launch_state" | awk -F'= ' '/last exit code =/{print $2; exit}'
}

install_daemon() {
  local binary
  local health_status=0
  if ! binary=$(find_binary); then
    echo "Error: canonical $BINARY_NAME not found. Install it first with ./scripts/install-macos.sh"
    exit 1
  fi

  if ! "$binary" permission-status; then
    echo "Permission setup is incomplete; the LaunchAgent was not installed." >&2
    echo "Resume with: scripts/install-macos.sh --continue-install" >&2
    return 2
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

  # Load the daemon from a clean socket path. A prior process may have exited
  # before removing its owned socket, so file existence is not health evidence.
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$SOCKET_PATH"
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  if wait_for_daemon_health; then
    echo "Daemon started and health check passed. Socket: $SOCKET_PATH"
  else
    local last_exit
    last_exit="$(launch_agent_last_exit_code || true)"
    if [[ "$last_exit" == "2" ]]; then
      if launchctl bootout "gui/$(id -u)/$LABEL"; then
        rm -f "$SOCKET_PATH" "$PLIST_PATH"
        health_status=2
        echo "Permission setup is incomplete in the LaunchAgent runtime." >&2
        echo "The installer will continue with interactive onboarding." >&2
      else
        health_status=1
        echo "WARNING: permission setup is incomplete, and the unhealthy LaunchAgent could not be stopped." >&2
        echo "Run: launchctl bootout gui/$(id -u)/$LABEL" >&2
      fi
    else
      health_status=1
      echo "WARNING: LaunchAgent loaded, but the daemon is not healthy." >&2
      echo "Run: $0 status" >&2
    fi
  fi
  echo "Logs: $LOG_DIR/daemon.log"
  echo ""
  echo "Important: run 'accio-computer-use setup' first and grant permissions"
  echo "to Accio Computer Use.app. The daemon should use the app-bundled CLI"
  echo "symlink installed by scripts/install-macos.sh."
  return "$health_status"
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
  local launch_state=""
  local last_exit=""
  launch_state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null || true)"

  if daemon_is_healthy; then
    echo "Status: running"
    echo "Socket: $SOCKET_PATH"
    return 0
  fi

  if [[ -n "$launch_state" ]]; then
    echo "Status: loaded but unhealthy"
    echo "Socket: $SOCKET_PATH"
    last_exit="$(printf '%s\n' "$launch_state" | awk -F'= ' '/last exit code =/{print $2; exit}')"
    if [[ -n "$last_exit" ]]; then
      echo "Last exit code: $last_exit"
    fi
    echo "LaunchAgent is loaded, but no live current-user listener is available."
    echo "Logs: $LOG_DIR/daemon.err"
    if [[ "$last_exit" == "2" ]]; then
      return 2
    fi
    return 1
  fi

  echo "Status: not running"
  echo "Socket: $SOCKET_PATH"
  return 1
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
