#!/usr/bin/env bash
# Build and install Accio Computer Use as one macOS app-bundled CLI package.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
if [[ ! -r "$VERSION_FILE" ]]; then
  echo "install-macos.sh: version file missing: $VERSION_FILE" >&2
  exit 1
fi
PROJECT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$PROJECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "install-macos.sh: invalid semantic version in $VERSION_FILE" >&2
  exit 1
fi
SIGNING_POLICY="$REPO_ROOT/scripts/lib/install-macos-signing-policy.sh"
if [[ ! -r "$SIGNING_POLICY" ]]; then
  echo "install-macos.sh: signing policy helper missing: $SIGNING_POLICY" >&2
  exit 1
fi
# shellcheck source=lib/install-macos-signing-policy.sh
source "$SIGNING_POLICY"
if [[ -z "${PREFIX:-}" ]]; then
  if [[ -w /usr/local/bin ]] || [[ -w /usr/local ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="$HOME/.local"
  fi
fi
INSTALL_DIR="${PREFIX%/}/bin"
BINARY_NAME="accio-computer-use"
CODING_RUNNER_NAME="runner.py"
APP_NAME="Accio Computer Use"
APP_BUNDLE="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.accio.computeruse"

VERIFY=false
UNINSTALL=false
INSTALL_SKILL=false
SKILL_TARGET="codex"
SKILL_ONLY=false
RESET_PERMISSIONS=false
CONTINUE_INSTALL=false
NO_ONBOARDING=false
SIGNING_MODE="${ACCIO_SIGNING_MODE:-local}"
SIGNING_IDENTITY="${ACCIO_CODESIGN_IDENTITY:-}"
LOCAL_SIGNING_IDENTITY_NAME="Accio Computer Use Local Development"
REINSTALL_DAEMON=false
DAEMON_WAS_LOADED=false
UPGRADE_DAEMON_STOPPED=false
UPGRADE_DAEMON_REINSTALLED=false
DAEMON_RESTART_HEALTHY=true
ONBOARDING_COMPLETED=false
DAEMON_LABEL="com.accio.computeruse.daemon"
DAEMON_PLIST="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"

usage() {
  cat <<'EOF'
Usage: install-macos.sh [options]

  --verify                 Run `accio-computer-use doctor` after install.
  --install-skill [TARGET] Install the agent skill. TARGET: codex, claude, or a directory.
                           Defaults to codex when TARGET is omitted.
  --skill-only [TARGET]    Install only the agent skill and skip app/CLI install.
  --reset-permissions      Reset Accio's Accessibility and Screen Recording grants after install.
                           Use when macOS keeps stale TCC records after local rebuilds.
  --continue-install       Resume permission setup, daemon install, and verification without rebuilding.
  --no-onboarding          Install the package without interactive permission setup or daemon install.
  --signing-identity ID    Sign with a persistent keychain identity or SHA-1 hash.
                           Overrides --signing-mode and ACCIO_SIGNING_MODE.
  --signing-mode MODE      local (default), explicit, or adhoc.
  --uninstall              Stop Accio, clear its two macOS grants, and remove the app/CLI.
  --prefix PATH            Install prefix (default: /usr/local). May also set PREFIX env.

Environment:
  PREFIX                   Same as --prefix when --prefix is not passed.
  CODEX_HOME               Codex skill root parent (default: ~/.codex).
  ACCIO_CODESIGN_IDENTITY  Persistent local or Developer ID signing identity.
  ACCIO_SIGNING_MODE       Default signing mode when no identity is supplied.

Examples:
  ./scripts/install-macos.sh
  ./scripts/install-macos.sh --verify --install-skill
  ./scripts/install-macos.sh --install-skill claude
  ./scripts/install-macos.sh --skill-only
  ./scripts/install-macos.sh --verify --reset-permissions
  ./scripts/install-macos.sh --signing-identity "Developer ID Application: Example (TEAMID)"
  ./scripts/install-macos.sh --signing-mode adhoc --no-onboarding --verify
  ./scripts/install-macos.sh --continue-install
  ./scripts/install-macos.sh --install-skill "$HOME/.config/my-agent/skills"
  PREFIX="$HOME/.local" ./scripts/install-macos.sh --verify
  ./scripts/install-macos.sh --uninstall
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      VERIFY=true
      ;;
    --install-skill)
      INSTALL_SKILL=true
      if [[ $# -ge 2 && "$2" != -* ]]; then
        SKILL_TARGET="$2"
        shift
      fi
      ;;
    --install-skill=*)
      INSTALL_SKILL=true
      SKILL_TARGET="${1#*=}"
      ;;
    --skill-only)
      INSTALL_SKILL=true
      SKILL_ONLY=true
      if [[ $# -ge 2 && "$2" != -* ]]; then
        SKILL_TARGET="$2"
        shift
      fi
      ;;
    --skill-only=*)
      INSTALL_SKILL=true
      SKILL_ONLY=true
      SKILL_TARGET="${1#*=}"
      ;;
    --reset-permissions)
      RESET_PERMISSIONS=true
      ;;
    --continue-install)
      CONTINUE_INSTALL=true
      ;;
    --no-onboarding)
      NO_ONBOARDING=true
      ;;
    --signing-identity)
      if [[ $# -lt 2 ]]; then
        echo "install-macos.sh: --signing-identity requires an identity" >&2
        exit 1
      fi
      SIGNING_IDENTITY="$2"
      SIGNING_MODE="explicit"
      shift
      ;;
    --signing-identity=*)
      SIGNING_IDENTITY="${1#*=}"
      SIGNING_MODE="explicit"
      ;;
    --signing-mode)
      if [[ $# -lt 2 ]]; then
        echo "install-macos.sh: --signing-mode requires local, explicit, or adhoc" >&2
        exit 1
      fi
      SIGNING_MODE="$2"
      shift
      ;;
    --signing-mode=*)
      SIGNING_MODE="${1#*=}"
      ;;
    --uninstall)
      UNINSTALL=true
      ;;
    --prefix)
      if [[ $# -lt 2 ]]; then
        echo "install-macos.sh: --prefix requires a path" >&2
        exit 1
      fi
      PREFIX="$2"
      INSTALL_DIR="${PREFIX%/}/bin"
      shift
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      INSTALL_DIR="${PREFIX%/}/bin"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install-macos.sh: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

TARGET_PATH="${INSTALL_DIR}/${BINARY_NAME}"
LEGACY_CODE_COMMAND_PATH="${INSTALL_DIR}/accio-cu-code"
SKILL_SOURCE="$REPO_ROOT/Skills/accio-computer-use"
CODING_SOURCE="$REPO_ROOT/coding"
LEGACY_CODE_RESOURCE="$APP_BUNDLE/Contents/Resources/coding/accio-cu-code"

if [[ "$CONTINUE_INSTALL" == true && "$UNINSTALL" == true ]]; then
  echo "install-macos.sh: --continue-install cannot be combined with --uninstall" >&2
  exit 1
fi
if [[ "$CONTINUE_INSTALL" == true && "$SKILL_ONLY" == true ]]; then
  echo "install-macos.sh: --continue-install cannot be combined with --skill-only" >&2
  exit 1
fi

remove_verified_legacy_code_command() {
  if [[ ! -e "$LEGACY_CODE_COMMAND_PATH" ]] && [[ ! -L "$LEGACY_CODE_COMMAND_PATH" ]]; then
    return 0
  fi
  if [[ ! -L "$LEGACY_CODE_COMMAND_PATH" ]] || \
     [[ "$(readlink "$LEGACY_CODE_COMMAND_PATH")" != "$LEGACY_CODE_RESOURCE" ]]; then
    echo "Warning: preserving unrelated path at $LEGACY_CODE_COMMAND_PATH" >&2
    return 0
  fi
  if [[ -w "$INSTALL_DIR" ]]; then
    rm -f "$LEGACY_CODE_COMMAND_PATH"
  else
    sudo rm -f "$LEGACY_CODE_COMMAND_PATH"
  fi
  echo "Removed legacy command: $LEGACY_CODE_COMMAND_PATH"
}

install_agent_skill() {
  local target="$1"
  local skills_dir

  if [[ ! -d "$SKILL_SOURCE" ]]; then
    echo "install-macos.sh: skill source missing: $SKILL_SOURCE" >&2
    exit 1
  fi

  case "$target" in
    codex)
      skills_dir="${CODEX_HOME:-$HOME/.codex}/skills"
      ;;
    claude)
      skills_dir="$HOME/.claude/skills"
      ;;
    *)
      skills_dir="$target"
      ;;
  esac

  mkdir -p "$skills_dir"
  rm -rf "$skills_dir/accio-computer-use"
  cp -R "$SKILL_SOURCE" "$skills_dir/accio-computer-use"
  echo "Installed agent skill: $skills_dir/accio-computer-use"
}

installed_runner_smoke_test() {
  local binary="${1:-}"
  [[ -x "$binary" ]] || {
    echo "install-macos.sh: installed binary is unavailable: $binary" >&2
    return 1
  }
  echo "Running installed Python runner smoke test..."
  env -u ACCIO_COMPUTER_USE_CODING_RUNNER "$binary" code --version
}

finish_onboarding() {
  local app_binary="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

  if [[ ! -x "$app_binary" ]] || \
     ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "install-macos.sh: no valid installed Accio app is available to continue." >&2
    echo "Run: ./scripts/install-macos.sh --install-skill" >&2
    return 1
  fi

  echo "Starting first-run permission setup."
  echo "If interrupted, resume without rebuilding: ./scripts/install-macos.sh --continue-install"
  if ! env -u ACCIO_COMPUTER_USE_CODING_RUNNER \
      "$app_binary" setup --wait-for-permissions; then
    echo "Installation is complete, but permission setup is pending." >&2
    echo "Resume with: ./scripts/install-macos.sh --continue-install" >&2
    return 2
  fi

  echo "Installing and verifying the background daemon..."
  ACCIO_COMPUTER_USE_BINARY="$app_binary" "$REPO_ROOT/scripts/install-daemon.sh" install
  "$REPO_ROOT/scripts/install-daemon.sh" status
  installed_runner_smoke_test "$app_binary"
  echo "Accio Computer Use installation is complete."
}

quit_running_app_bundle() {
  if [[ ! -d "$APP_BUNDLE" ]]; then
    return
  fi

  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  local app_binary="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
  if ! accio_terminate_exact_process "$app_binary" 5 20 0.2 "$TARGET_PATH"; then
    echo "install-macos.sh: refusing to replace the app while its old process is still running." >&2
    echo "Quit Accio Computer Use and retry the installer." >&2
    return 1
  fi
}

if [[ "$UNINSTALL" == true ]]; then
  # Public tccutil can scope resets to a bundle identifier, not to a legacy
  # path-based executable identity. Refuse to claim a clean uninstall for that
  # unsupported layout instead of globally clearing other apps' permissions.
  if accio_legacy_standalone_install_exists \
       "$TARGET_PATH" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"; then
    echo "install-macos.sh: legacy standalone CLI detected at $TARGET_PATH" >&2
    echo "Remove its entries from Accessibility and Screen Recording in System Settings," >&2
    echo "then remove the standalone file before rerunning --uninstall." >&2
    exit 1
  fi

  # Stop the persistent daemon before checking the app-bundled executable. A
  # KeepAlive job could otherwise restart it while the bundle is being removed.
  LEGACY_PLIST="$HOME/Library/LaunchAgents/com.accio.computeruse.daemon.plist"
  UNINSTALL_DAEMON_WAS_LOADED=false
  if accio_launch_agent_is_loaded "$DAEMON_LABEL"; then
    if [[ ! -f "$LEGACY_PLIST" ]]; then
      echo "install-macos.sh: loaded daemon has no recoverable plist at $LEGACY_PLIST" >&2
      echo "Stop it manually with launchctl bootout, then retry --uninstall." >&2
      exit 1
    fi
    UNINSTALL_DAEMON_WAS_LOADED=true
    if ! accio_stop_loaded_launch_agent "$DAEMON_LABEL"; then
      echo "install-macos.sh: uninstall aborted because the persistent daemon could not be stopped." >&2
      exit 1
    fi
  fi

  restore_uninstall_daemon() {
    if [[ "$UNINSTALL_DAEMON_WAS_LOADED" != true ]]; then
      return 0
    fi
    if [[ ! -f "$LEGACY_PLIST" ]]; then
      echo "install-macos.sh: cannot restore the previously loaded daemon; plist is missing." >&2
      return 1
    fi
    if ! accio_launch_agent_is_loaded "$DAEMON_LABEL" && \
       ! /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$LEGACY_PLIST" 2>/dev/null; then
      echo "install-macos.sh: failed to restore the previously loaded daemon." >&2
      return 1
    fi
  }

  if ! quit_running_app_bundle; then
    restore_uninstall_daemon
    echo "install-macos.sh: uninstall aborted because an Accio process is still running." >&2
    exit 1
  fi

  # Removing an app does not remove its TCC records. Clear only Accio's two
  # grants before deleting the bundle so a later reinstall starts untrusted.
  echo "Clearing Accio Accessibility and Screen Recording permissions..."
  if ! accio_reset_scoped_tcc_permissions "$BUNDLE_ID"; then
    echo "install-macos.sh: uninstall aborted because Accio's permissions could not be cleared." >&2
    echo "No app or CLI files were removed." >&2
    restore_uninstall_daemon
    exit 1
  fi
  echo "Cleared Accio Accessibility and Screen Recording permissions"

  # Clean up any legacy daemon LaunchAgent from older installs.
  if [[ -f "$LEGACY_PLIST" ]]; then
    rm -f "$LEGACY_PLIST"
    rm -f "/tmp/accio-computer-use.sock"
    rm -f "/tmp/accio-computer-use-$(id -u).sock"
    rm -f "/tmp/accio-computer-use-$(id -u)/daemon.sock"
    rmdir "/tmp/accio-computer-use-$(id -u)" 2>/dev/null || true
    echo "Removed legacy daemon LaunchAgent"
  fi

  # Remove CLI symlink (or legacy standalone binary)
  if [[ -e "$TARGET_PATH" ]] || [[ -L "$TARGET_PATH" ]]; then
    if [[ -w "$INSTALL_DIR" ]]; then
      rm -f "$TARGET_PATH"
    else
      sudo rm -f "$TARGET_PATH"
    fi
    echo "Removed $TARGET_PATH"
  else
    echo "Nothing to remove at $TARGET_PATH"
  fi

  remove_verified_legacy_code_command

  # Remove .app bundle (holds the real binary)
  if [[ -e "$APP_BUNDLE" ]] || [[ -L "$APP_BUNDLE" ]]; then
    if [[ -w "/Applications" ]]; then
      rm -rf "$APP_BUNDLE"
    else
      sudo rm -rf "$APP_BUNDLE"
    fi
    echo "Removed $APP_BUNDLE"
  fi
  exit 0
fi

if [[ "$SKILL_ONLY" == true ]]; then
  install_agent_skill "$SKILL_TARGET"
  exit 0
fi

if [[ "$CONTINUE_INSTALL" == true ]]; then
  if [[ "$NO_ONBOARDING" == true ]]; then
    echo "install-macos.sh: --continue-install cannot be combined with --no-onboarding" >&2
    exit 1
  fi
  finish_onboarding
  exit $?
fi

case "$SIGNING_MODE" in
  local)
    if [[ -n "$SIGNING_IDENTITY" ]]; then
      SIGNING_MODE="explicit"
    else
      echo "Preparing persistent local signing identity: $LOCAL_SIGNING_IDENTITY_NAME"
      SIGNING_IDENTITY="$(accio_ensure_local_signing_identity "$LOCAL_SIGNING_IDENTITY_NAME")" || exit 1
    fi
    ;;
  explicit)
    if [[ -z "$SIGNING_IDENTITY" ]]; then
      echo "install-macos.sh: explicit signing mode requires --signing-identity or ACCIO_CODESIGN_IDENTITY" >&2
      exit 1
    fi
    ;;
  adhoc)
    if [[ -n "$SIGNING_IDENTITY" ]]; then
      echo "install-macos.sh: adhoc signing mode cannot be combined with a signing identity" >&2
      exit 1
    fi
    SIGNING_IDENTITY="-"
    ;;
  *)
    echo "install-macos.sh: invalid signing mode '$SIGNING_MODE' (expected local, explicit, or adhoc)" >&2
    exit 1
    ;;
esac
if ! accio_validate_signing_identity "$SIGNING_IDENTITY"; then
  exit 1
fi

# Preserve the daemon's actual loaded state across upgrades. A plist that is
# present but intentionally unloaded must remain unloaded.
if accio_launch_agent_is_loaded "$DAEMON_LABEL"; then
  if [[ ! -f "$DAEMON_PLIST" ]]; then
    echo "install-macos.sh: loaded daemon has no recoverable plist at $DAEMON_PLIST" >&2
    echo "Stop it manually with launchctl bootout, then retry the installer." >&2
    exit 1
  fi
  DAEMON_WAS_LOADED=true
  REINSTALL_DAEMON=true
fi

cd "$REPO_ROOT"
PROJECT_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  PROJECT_REVISION="${PROJECT_REVISION}-dirty"
fi
BIN_DIR="$(swift build -c release --product AccioComputerUse --show-bin-path)"
swift build -c release --product AccioComputerUse
SRC_BINARY="${BIN_DIR}/AccioComputerUse"

if [[ ! -f "$SRC_BINARY" ]]; then
  echo "install-macos.sh: expected binary missing: $SRC_BINARY" >&2
  exit 1
fi

if [[ ! -f "$CODING_SOURCE/$CODING_RUNNER_NAME" ]] || [[ ! -d "$CODING_SOURCE/accio_cu_code" ]]; then
  echo "install-macos.sh: coding harness missing from $CODING_SOURCE" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "install-macos.sh: python3 is required for coding mode" >&2
  exit 1
fi

# --- Install the app-bundled CLI package ---
echo "Installing app-bundled CLI package:"
echo "  app: $APP_BUNDLE"
echo "  cli: $TARGET_PATH"
echo "  signing identity: $SIGNING_IDENTITY"

# Capture the old designated requirement before replacing the application.
# TCC grants remain valid only when the new build satisfies the same DR.
PREVIOUS_DESIGNATED_REQUIREMENT=""
if [[ -d "$APP_BUNDLE" ]]; then
  if ! PREVIOUS_DESIGNATED_REQUIREMENT="$(accio_designated_requirement "$APP_BUNDLE")"; then
    PREVIOUS_DESIGNATED_REQUIREMENT="invalid-existing-signature"
  fi
fi

# Build and sign as the logged-in user so a Developer ID or persistent local
# identity can access the user's login keychain. sudo is used only for the final
# copy into /Applications when that directory is not user-writable.
STAGING_PARENT="${TMPDIR:-/tmp}"
STAGING_PARENT="${STAGING_PARENT%/}"
STAGING_ROOT="$(mktemp -d "$STAGING_PARENT/accio-computer-use-install.XXXXXX")"
STAGED_APP_BUNDLE="$STAGING_ROOT/${APP_NAME}.app"
cleanup_staging() {
  if [[ -n "${STAGING_ROOT:-}" && \
        "$STAGING_ROOT" == "$STAGING_PARENT"/accio-computer-use-install.* && \
        -d "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
  fi
  if [[ "${UPGRADE_DAEMON_STOPPED:-false}" == true && \
        "${UPGRADE_DAEMON_REINSTALLED:-false}" != true && \
        -f "$DAEMON_PLIST" ]] && \
     ! accio_launch_agent_is_loaded "$DAEMON_LABEL"; then
    if ! /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$DAEMON_PLIST" 2>/dev/null; then
      echo "install-macos.sh: failed to restore the previously loaded daemon after installation failure." >&2
    fi
  fi
}
trap cleanup_staging EXIT

mkdir -p "$STAGED_APP_BUNDLE/Contents/MacOS"
mkdir -p "$STAGED_APP_BUNDLE/Contents/Resources"

# The .app bundle holds the only real copy of the binary.
# CLI access is via symlink (see below), so the app and CLI share one signing
# identity. A persistent certificate keeps that identity stable across builds.
cp -f "$SRC_BINARY" "$STAGED_APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# The internal coding runtime is full Python. Its preloaded helpers route native
# calls through the supervisor and daemon; it does not embed the native backend.
mkdir -p "$STAGED_APP_BUNDLE/Contents/Resources/coding"
mkdir -p "$STAGED_APP_BUNDLE/Contents/Resources/coding/accio_cu_code"
for coding_module in "$CODING_SOURCE"/accio_cu_code/*.py; do
  cp -f "$coding_module" "$STAGED_APP_BUNDLE/Contents/Resources/coding/accio_cu_code/"
done
cp -f "$CODING_SOURCE/$CODING_RUNNER_NAME" "$STAGED_APP_BUNDLE/Contents/Resources/coding/$CODING_RUNNER_NAME"

# Copy icon if available
ICON_SOURCE="$REPO_ROOT/resources/AppIcon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
  cp -f "$ICON_SOURCE" "$STAGED_APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Write Info.plist
tee "$STAGED_APP_BUNDLE/Contents/Info.plist" > /dev/null <<INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$PROJECT_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$PROJECT_VERSION</string>
    <key>AccioBuildRevision</key>
    <string>$PROJECT_REVISION</string>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Accio uses macOS Screen Recording permission for on-demand interface screenshots requested by an AI agent. It does not continuously record video.</string>
</dict>
</plist>
INFOPLIST

# Let codesign synthesize the certificate-bound designated requirement. Never
# replace it with an identifier-only custom requirement: that would allow code
# signed by another party to impersonate this permission identity.
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$STAGED_APP_BUNDLE"
codesign --verify --deep --strict "$STAGED_APP_BUNDLE"
NEW_DESIGNATED_REQUIREMENT="$(accio_designated_requirement "$STAGED_APP_BUNDLE")"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  if ! accio_validate_stable_requirement "$NEW_DESIGNATED_REQUIREMENT" "$BUNDLE_ID"; then
    echo "install-macos.sh: persistent signing identity produced an unstable designated requirement:" >&2
    echo "  $NEW_DESIGNATED_REQUIREMENT" >&2
    exit 1
  fi
fi

SIGNING_PLAN="$(accio_signing_plan \
  "$SIGNING_IDENTITY" \
  "$RESET_PERMISSIONS" \
  "$PREVIOUS_DESIGNATED_REQUIREMENT" \
  "$NEW_DESIGNATED_REQUIREMENT")"
IFS='|' read -r SIGNING_MODE PERMISSION_ACTION <<< "$SIGNING_PLAN"

if [[ "$REINSTALL_DAEMON" == true ]]; then
  # A KeepAlive LaunchAgent would otherwise restart the old executable while
  # the bundle is being replaced. It is installed again after the new copy.
  if ! accio_stop_loaded_launch_agent "$DAEMON_LABEL"; then
    echo "install-macos.sh: refusing to replace the app while its daemon is still loaded." >&2
    exit 1
  fi
  UPGRADE_DAEMON_STOPPED=true
fi
quit_running_app_bundle
if [[ -w "/Applications" ]]; then
  rm -rf "$APP_BUNDLE"
  /usr/bin/ditto "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
else
  sudo rm -rf "$APP_BUNDLE"
  sudo /usr/bin/ditto "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

# Register with Launch Services so Finder, Launchpad, and System Settings can
# resolve the freshly installed bundle. A silent registration failure leaves a
# valid app on disk that appears impossible to open by name.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if ! accio_register_app_bundle "$LSREGISTER" "$APP_BUNDLE"; then
  echo "install-macos.sh: app installed, but Launch Services registration failed." >&2
  echo "Retry: $LSREGISTER -f \"$APP_BUNDLE\"" >&2
  exit 1
fi

if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  echo "WARNING: using ad-hoc signing. Any changed build has a new macOS permission identity." >&2
  echo "         Set --signing-identity or ACCIO_CODESIGN_IDENTITY to a persistent certificate." >&2
fi

if [[ "$PERMISSION_ACTION" == "reset" ]]; then
  echo "Resetting Accio's Accessibility and Screen Recording grants for the selected signing plan."
  if ! accio_reset_scoped_tcc_permissions "$BUNDLE_ID"; then
    echo "install-macos.sh: the app was installed, but stale permission records could not be reset." >&2
    echo "Run: tccutil reset Accessibility $BUNDLE_ID" >&2
    echo "     tccutil reset ScreenCapture $BUNDLE_ID" >&2
    exit 1
  fi
  echo "Re-enable both permissions in System Settings, then restart Accio Computer Use."
fi

echo "App permission container installed: $APP_BUNDLE"

# --- CLI symlink points into the .app bundle ---
# One app-bundled binary and one designated requirement. Granting permissions
# to the app covers CLI usage through the symlink below.
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

if [[ -w "$INSTALL_DIR" ]] 2>/dev/null; then
  mkdir -p "$INSTALL_DIR"
  ln -sf "$APP_BINARY" "$TARGET_PATH"
elif mkdir -p "$INSTALL_DIR" 2>/dev/null && [[ -w "$INSTALL_DIR" ]]; then
  ln -sf "$APP_BINARY" "$TARGET_PATH"
else
  sudo mkdir -p "$INSTALL_DIR"
  sudo ln -sf "$APP_BINARY" "$TARGET_PATH"
fi

echo "Symlinked: $TARGET_PATH → $APP_BINARY"

PATH_COMMAND="$(command -v "$BINARY_NAME" 2>/dev/null || true)"
if [[ -n "$PATH_COMMAND" ]]; then
  PATH_COMMAND_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PATH_COMMAND")"
  APP_BINARY_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$APP_BINARY")"
  if [[ "$PATH_COMMAND_REAL" != "$APP_BINARY_REAL" ]]; then
    echo "WARNING: PATH resolves $BINARY_NAME to an older or unrelated copy:" >&2
    echo "  $PATH_COMMAND → $PATH_COMMAND_REAL" >&2
    echo "Expected the installed command to resolve to:" >&2
    echo "  $APP_BINARY_REAL" >&2
    echo "Remove the shadowing command or place $INSTALL_DIR earlier in PATH, then refresh the shell command cache." >&2
  fi
fi

# Older installs exposed the Python runner as a second command. The native
# app-bundled binary now owns both native commands and coding mode.
remove_verified_legacy_code_command

if [[ "$INSTALL_SKILL" == true ]]; then
  install_agent_skill "$SKILL_TARGET"
fi

if [[ "$REINSTALL_DAEMON" == true ]]; then
  DAEMON_INSTALL_STATUS=0
  echo "Migrating existing daemon LaunchAgent to the private socket path..."
  if ACCIO_COMPUTER_USE_BINARY="$TARGET_PATH" "$REPO_ROOT/scripts/install-daemon.sh" install; then
    echo "Daemon health check passed."
    UPGRADE_DAEMON_REINSTALLED=true
  else
    DAEMON_INSTALL_STATUS=$?
    DAEMON_RESTART_HEALTHY=false
    DAEMON_FAILURE_ACTION="$(accio_daemon_reinstall_failure_action \
      "$DAEMON_INSTALL_STATUS" "$NO_ONBOARDING")"
    if [[ "$DAEMON_FAILURE_ACTION" == "onboard" ]]; then
      # Package replacement succeeded. Do not restore a KeepAlive job while
      # permissions are pending; finish_onboarding installs it only after the
      # canonical app passes both runtime permission probes.
      UPGRADE_DAEMON_REINSTALLED=true
      finish_onboarding
      ONBOARDING_COMPLETED=true
      DAEMON_RESTART_HEALTHY=true
    elif [[ "$DAEMON_FAILURE_ACTION" == "permission-pending" ]]; then
      # The package upgrade succeeded, but the new canonical binary does not
      # have effective permissions. Keep the old LaunchAgent stopped instead
      # of letting the EXIT trap restore a KeepAlive job that cannot start.
      UPGRADE_DAEMON_REINSTALLED=true
      echo "Permission setup is pending and onboarding was disabled." >&2
      echo "Resume with: $REPO_ROOT/scripts/install-macos.sh --continue-install" >&2
      exit 2
    else
      echo "install-macos.sh: daemon reinstall failed with status $DAEMON_INSTALL_STATUS." >&2
      echo "This is not a permission-pending result; onboarding was not started." >&2
      exit "$DAEMON_INSTALL_STATUS"
    fi
  fi
elif [[ "$NO_ONBOARDING" != true && ! -f "$DAEMON_PLIST" ]]; then
  finish_onboarding
  ONBOARDING_COMPLETED=true
fi

if [[ "$VERIFY" != true && "$ONBOARDING_COMPLETED" != true ]]; then
  installed_runner_smoke_test "$APP_BINARY"
fi

# Warn if a stale binary or symlink elsewhere in PATH would shadow the new one.
# The supported permission model is: app bundle owns the real binary, PATH
# points to that binary through a symlink. A standalone CLI gets a separate TCC
# identity and will not share the app's Accessibility/Screen Recording grants.
FOUND_IN_PATH="$(command -v "$BINARY_NAME" 2>/dev/null || true)"
if [[ -n "$FOUND_IN_PATH" ]] && [[ "$FOUND_IN_PATH" != "$TARGET_PATH" ]]; then
  echo ""
  echo "  WARNING: your shell currently resolves '$BINARY_NAME' to:"
  echo "    $FOUND_IN_PATH"
  echo "  but this installer created the app-bundled CLI symlink at:"
  echo "    $TARGET_PATH -> $APP_BINARY"
  echo ""
  echo "  Move $INSTALL_DIR earlier in PATH, remove the shadowing entry, or run:"
  echo "    $TARGET_PATH setup"
  echo ""
  echo "  A standalone CLI has a separate macOS TCC identity and will not share"
  echo "  permissions granted to Accio Computer Use.app."
fi

if [[ "$TARGET_PATH" == "$HOME"* ]] && ! echo "$PATH" | tr ':' '\n' | grep -q "^${INSTALL_DIR}$"; then
  echo ""
  echo "  Add $INSTALL_DIR to your PATH if not already present:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

cat <<'EOF'

Install model
-------------
This is one combined install. You do not install a separate CLI and a separate
app. The app bundle is the permission container and owns the real executable:

  /Applications/Accio Computer Use.app/Contents/MacOS/accio-computer-use

The CLI installed into your PATH is only a symlink to that executable. Installing
the app therefore installs the CLI too, and granting permissions to the app
covers CLI, daemon, and MCP usage.

Piping Python into `accio-computer-use` executes coding mode outside the native
daemon with self-describing Computer Use helpers preloaded. It requires a
running daemon and never falls back to local native execution. Isolation for
untrusted rollouts belongs to the VM, user-session, or orchestration layer.

macOS permissions
-----------------
Accio Computer Use needs two settings (System Settings → Privacy & Security):

  1. Accessibility — find "Accio Computer Use" in the application list and enable it.

  2. Screen Recording — find "Accio Computer Use" in the application list and enable it.
     macOS uses this permission name for screenshots. Accio captures images only
     when an agent requests the current interface; it does not continuously record video.

Seeing "Accio Computer Use" in these macOS app lists is expected: this is how
macOS grants permissions to the shared app-bundled binary.

Normal installs complete permission setup and daemon verification automatically.
If the permission flow was interrupted, resume without rebuilding:

  scripts/install-macos.sh --continue-install

The standalone setup assistant remains available for diagnostics, MCP
configuration, daemon status, and automation-pause status. During use, the menu
bar app and the top-of-screen activity pill show when Accio is observing or
acting. For script-only diagnostics, run:

  accio-computer-use doctor

The default local signing mode creates and reuses an identity in your login
keychain so permissions survive rebuilds. You may instead install every build
with the same --signing-identity (or ACCIO_CODESIGN_IDENTITY). The installer
compares old and new designated requirements. Ad-hoc installs always reset only
Accio's two grants; persistent identities reset them only when changed or
explicitly requested.

EOF

if [[ "$VERIFY" == true ]]; then
  echo "Running: $TARGET_PATH doctor"
  "$TARGET_PATH" doctor
  echo ""
  if [[ "$REINSTALL_DAEMON" == true || "$ONBOARDING_COMPLETED" == true ]]; then
    if [[ "$DAEMON_RESTART_HEALTHY" != true ]]; then
      echo "Retrying daemon health after installation diagnostics..."
    fi
    echo "Running persistent daemon health check..."
    if ! "$REPO_ROOT/scripts/install-daemon.sh" status; then
      echo "install-macos.sh: verification failed because the persistent daemon is unhealthy." >&2
      exit 1
    fi
    DAEMON_RESTART_HEALTHY=true
    echo ""
  fi
  echo "Running coding runner smoke test through the installed CLI path..."
  env -u ACCIO_COMPUTER_USE_CODING_RUNNER "$TARGET_PATH" code --version
  echo ""
  echo "Running coding runner smoke test through PATH command lookup..."
  env -u ACCIO_COMPUTER_USE_CODING_RUNNER \
    PATH="$INSTALL_DIR:$PATH" "$BINARY_NAME" code --version
  echo ""
  echo "Installation verification completed."
fi
