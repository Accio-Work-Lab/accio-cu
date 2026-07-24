#!/usr/bin/env bash

# Pure policy helper sourced by install-macos.sh and its tests.
# Output format: <adhoc|stable>|<reset|preserve>
accio_validate_signing_identity() {
  local identity="${1:-}"
  if [[ -z "$identity" ]] || [[ "$identity" =~ [[:cntrl:]] ]]; then
    echo "install-macos-signing-policy: signing identity is empty or contains control characters" >&2
    return 64
  fi
}

accio_designated_requirement() {
  local app_path="${1:-}"
  local output
  local line
  [[ -n "$app_path" ]] || return 64
  output="$(codesign -d -r- "$app_path" 2>&1)" || return 1
  while IFS= read -r line; do
    if [[ "$line" == *"designated =>"* ]]; then
      printf 'designated =>%s\n' "${line#*designated =>}"
      return 0
    fi
  done <<< "$output"
  return 1
}

accio_signing_plan() {
  local identity="${1:-}"
  local explicit_reset="${2:-false}"
  local previous_requirement="${3:-}"
  local new_requirement="${4:-}"

  accio_validate_signing_identity "$identity" || return
  if [[ "$explicit_reset" != "true" && "$explicit_reset" != "false" ]]; then
    echo "install-macos-signing-policy: explicit reset must be true or false" >&2
    return 64
  fi
  if [[ -z "$new_requirement" ]]; then
    echo "install-macos-signing-policy: the new app has no designated requirement" >&2
    return 65
  fi

  local mode="stable"
  if [[ "$identity" == "-" ]]; then
    mode="adhoc"
  fi

  local permission_action="preserve"
  if [[ "$identity" == "-" || "$explicit_reset" == "true" ]]; then
    permission_action="reset"
  elif [[ -n "$previous_requirement" && "$previous_requirement" != "$new_requirement" ]]; then
    permission_action="reset"
  fi

  printf '%s|%s\n' "$mode" "$permission_action"
}

accio_validate_stable_requirement() {
  local requirement="${1:-}"
  local bundle_id="${2:-}"
  if [[ -z "$requirement" || -z "$bundle_id" ]]; then
    echo "install-macos-signing-policy: requirement and bundle identifier are required" >&2
    return 64
  fi
  if [[ "$requirement" != *"identifier \"$bundle_id\""* ]]; then
    echo "install-macos-signing-policy: designated requirement does not bind the expected bundle identifier" >&2
    return 65
  fi
  if [[ "$requirement" == *"cdhash H\""* ]]; then
    echo "install-macos-signing-policy: designated requirement is tied to one build cdhash" >&2
    return 65
  fi

  # Apple-issued identities are publisher-bound by the Apple anchor and Team
  # ID. A non-Apple local identity is accepted only when the DR pins a concrete
  # certificate hash. A bare `anchor trusted` is intentionally rejected.
  if [[ "$requirement" == *"anchor apple generic"* && \
        "$requirement" == *"certificate leaf[subject.OU]"* ]]; then
    return 0
  fi
  if [[ "$requirement" == *"certificate leaf = H\""* || \
        "$requirement" == *"anchor = H\""* ]]; then
    return 0
  fi

  echo "install-macos-signing-policy: designated requirement does not bind a concrete publisher" >&2
  return 65
}

accio_reset_scoped_tcc_permissions() {
  local bundle_id="${1:-}"
  if [[ "$bundle_id" != "com.accio.computeruse" ]]; then
    echo "install-macos-signing-policy: refusing to reset permissions for a non-Accio bundle" >&2
    return 64
  fi

  local failed=false
  if ! accio_tccutil reset Accessibility "$bundle_id"; then
    echo "Failed to reset Accessibility for $bundle_id" >&2
    failed=true
  fi
  if ! accio_tccutil reset ScreenCapture "$bundle_id"; then
    echo "Failed to reset Screen Recording for $bundle_id" >&2
    failed=true
  fi
  [[ "$failed" == "false" ]]
}

accio_tccutil() {
  /usr/bin/tccutil "$@"
}

accio_launchctl() {
  /bin/launchctl "$@"
}

accio_current_uid() {
  /usr/bin/id -u
}

accio_launch_agent_is_loaded() {
  local label="${1:-}"
  if [[ -z "$label" || "$label" =~ [^A-Za-z0-9._-] ]]; then
    return 64
  fi
  accio_launchctl print "gui/$(accio_current_uid)/$label" >/dev/null 2>&1
}

accio_stop_loaded_launch_agent() {
  local label="${1:-}"
  if ! accio_launch_agent_is_loaded "$label"; then
    return 0
  fi
  if ! accio_launchctl bootout "gui/$(accio_current_uid)/$label"; then
    echo "install-macos-signing-policy: failed to stop LaunchAgent $label" >&2
    return 1
  fi
  if accio_launch_agent_is_loaded "$label"; then
    echo "install-macos-signing-policy: LaunchAgent is still loaded: $label" >&2
    return 1
  fi
}

accio_legacy_standalone_install_exists() {
  local target_path="${1:-}"
  local expected_app_binary="${2:-}"
  if [[ -z "$target_path" || -z "$expected_app_binary" ]]; then
    return 64
  fi
  if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
    return 1
  fi
  if [[ ! -L "$target_path" || ! -e "$target_path" || ! -f "$expected_app_binary" || \
        ! -x "$expected_app_binary" || -L "$expected_app_binary" ]]; then
    return 0
  fi

  local link_destination=""
  if ! link_destination="$(/usr/bin/readlink "$target_path")"; then
    return 0
  fi
  if [[ "$link_destination" != /* ]]; then
    link_destination="$(/usr/bin/dirname "$target_path")/$link_destination"
  fi

  local resolved_link_directory=""
  local resolved_expected_directory=""
  if ! resolved_link_directory="$(cd -P "$(/usr/bin/dirname "$link_destination")" 2>/dev/null && pwd)" || \
     ! resolved_expected_directory="$(cd -P "$(/usr/bin/dirname "$expected_app_binary")" 2>/dev/null && pwd)"; then
    return 0
  fi
  local resolved_link="$resolved_link_directory/$(/usr/bin/basename "$link_destination")"
  local resolved_expected="$resolved_expected_directory/$(/usr/bin/basename "$expected_app_binary")"
  [[ "$resolved_link" == "$resolved_expected" ]] || return 0
  return 1
}

accio_register_app_bundle() {
  local registrar="${1:-}"
  local app_bundle="${2:-}"
  if [[ -z "$registrar" || ! -x "$registrar" || -z "$app_bundle" ]]; then
    echo "install-macos-signing-policy: invalid Launch Services registrar or app bundle" >&2
    return 64
  fi
  "$registrar" -f "$app_bundle"
}

accio_process_rows() {
  /bin/ps -axo pid=,command=
}

accio_process_executable_path() {
  local pid="${1:-}"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 64
  fi

  /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/awk '
    $0 == "ftxt" { next_line_is_text = 1; next }
    next_line_is_text && substr($0, 1, 1) == "n" {
      print substr($0, 2)
      exit
    }
  '
}

accio_pid_matches_expected_executable() {
  local pid="${1:-}"
  local expected_executable="${2:-}"
  if [[ ! "$pid" =~ ^[0-9]+$ || -z "$expected_executable" ]]; then
    return 64
  fi

  local expected_directory=""
  if ! expected_directory="$(cd -P "$(/usr/bin/dirname "$expected_executable")" 2>/dev/null && pwd)"; then
    return 2
  fi
  expected_executable="$expected_directory/$(/usr/bin/basename "$expected_executable")"

  local actual_executable=""
  if ! actual_executable="$(accio_process_executable_path "$pid")" || [[ -z "$actual_executable" ]]; then
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  fi
  [[ "$actual_executable" == "$expected_executable" ]]
}

accio_exact_process_pids() {
  local expected_executable="${1:-}"
  shift || true
  if [[ -z "$expected_executable" || "$expected_executable" =~ [[:cntrl:]] ]]; then
    return 64
  fi
  local requested_executable="$expected_executable"

  # lsof reports physical paths (for example /private/tmp rather than /tmp).
  # Normalize the expected executable without following the executable itself,
  # so a CLI symlink still resolves to the app bundle identity supplied first.
  local expected_directory=""
  if ! expected_directory="$(cd -P "$(/usr/bin/dirname "$expected_executable")" 2>/dev/null && pwd)"; then
    echo "install-macos-signing-policy: executable directory is unavailable: $expected_executable" >&2
    return 1
  fi
  expected_executable="$expected_directory/$(/usr/bin/basename "$expected_executable")"

  local process_rows=""
  if ! process_rows="$(accio_process_rows)"; then
    echo "install-macos-signing-policy: unable to enumerate running processes" >&2
    return 1
  fi

  local invocation_path
  local candidates=""
  for invocation_path in "$requested_executable" "$@"; do
    if [[ -z "$invocation_path" || "$invocation_path" =~ [[:cntrl:]] ]]; then
      return 64
    fi
    local matches=""
    if ! matches="$(/usr/bin/awk -v target="$invocation_path" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ($0 == target || index($0, target " ") == 1) print pid
    }
    ' <<< "$process_rows")"; then
      echo "install-macos-signing-policy: unable to inspect running processes" >&2
      return 1
    fi
    [[ -n "$matches" ]] && candidates="${candidates}${candidates:+$'\n'}${matches}"
  done

  local pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local actual_executable=""
    if ! actual_executable="$(accio_process_executable_path "$pid")"; then
      if kill -0 "$pid" 2>/dev/null; then
        echo "install-macos-signing-policy: unable to identify executable for PID $pid" >&2
        return 1
      fi
      continue
    fi
    if [[ -z "$actual_executable" ]]; then
      if kill -0 "$pid" 2>/dev/null; then
        echo "install-macos-signing-policy: empty executable identity for PID $pid" >&2
        return 1
      fi
      continue
    fi
    [[ "$actual_executable" == "$expected_executable" ]] && printf '%s\n' "$pid"
  done <<< "$candidates"
}

accio_terminate_exact_process() {
  local executable_path="${1:-}"
  local polite_attempts="${2:-5}"
  local terminate_attempts="${3:-20}"
  local interval_seconds="${4:-0.2}"
  local pids=""
  local executable_paths=("$executable_path")
  if (( $# > 4 )); then
    executable_paths+=("${@:5}")
  fi

  if [[ -z "$executable_path" || ! "$polite_attempts" =~ ^[0-9]+$ || \
        ! "$terminate_attempts" =~ ^[0-9]+$ || \
        ! "$interval_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "install-macos-signing-policy: invalid process termination arguments" >&2
    return 64
  fi

  local attempt
  for ((attempt = 0; attempt < polite_attempts; attempt++)); do
    if ! pids="$(accio_exact_process_pids "${executable_paths[@]}")"; then
      return 1
    fi
    [[ -z "$pids" ]] && return 0
    sleep "$interval_seconds"
  done

  if ! pids="$(accio_exact_process_pids "${executable_paths[@]}")"; then
    return 1
  fi
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if accio_pid_matches_expected_executable "$pid" "$executable_path"; then
        :
      else
        match_status=$?
        if [[ "$match_status" -ne 1 ]]; then
          echo "install-macos-signing-policy: unable to revalidate executable for PID $pid" >&2
          return 1
        fi
        continue
      fi
      if ! kill -TERM "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
        echo "install-macos-signing-policy: unable to terminate PID $pid" >&2
        return 1
      fi
    done <<< "$pids"
  fi

  for ((attempt = 0; attempt < terminate_attempts; attempt++)); do
    if ! pids="$(accio_exact_process_pids "${executable_paths[@]}")"; then
      return 1
    fi
    [[ -z "$pids" ]] && return 0
    sleep "$interval_seconds"
  done

  echo "Accio process did not exit: $executable_path" >&2
  return 1
}
