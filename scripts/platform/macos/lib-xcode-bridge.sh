#!/usr/bin/env bash
set -euo pipefail

# Repeated sourcing preserves owned state; inherited scalar state cannot claim ownership.
if ! declare -F xcode_bridge_start >/dev/null; then
  _XCODE_CHILD=''
  _XCODE_SESSION=''
  _XCODE_HELPER=''
  _XCODE_PYTHON=''
  _XCODE_PENDING_CHILD=''
  _XCODE_PENDING_SESSION=''
  _XCODE_PENDING_HELPER=''
  _XCODE_PENDING_PYTHON=''
  XCODE_BRIDGE_ACTIVE=0
  XCODE_DOCKER_ARGS=()
fi

# Indexed arrays and BASH_SOURCE retain compatibility with the macOS Bash 3.2 host.
_xcode_owned_child() {
  local candidate="$1" child
  while IFS= read -r child; do
    if [[ "$child" == "$candidate" ]]; then
      return 0
    fi
  done < <(jobs -pr)
  return 1
}

_xcode_remove_session() {
  local directory="$1" python="${2:-${_XCODE_PYTHON:-}}" helper="${3:-${_XCODE_HELPER:-}}"
  if [[ -n "$directory" && -d "$directory" && ! -L "$directory" ]]; then
    if [[ -n "$python" && -n "$helper" ]]; then
      "$python" "$helper" --session "$directory" --control cleanup >/dev/null 2>&1 || true
    fi
  fi
}

_xcode_finish_child() {
  local child="$1" attempts=0
  while _xcode_owned_child "$child" && (( attempts < 50 )); do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if _xcode_owned_child "$child"; then
    # This PID came from this shell's live job table, never from session metadata.
    kill -TERM "$child" 2>/dev/null || true
    attempts=0
    while _xcode_owned_child "$child" && (( attempts < 20 )); do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if _xcode_owned_child "$child"; then
      kill -KILL "$child" 2>/dev/null || true
    fi
  fi
  wait "$child" 2>/dev/null || true
}

_xcode_stop_pending() {
  if [[ -n "${_XCODE_PENDING_CHILD:-}" ]] && _xcode_owned_child "$_XCODE_PENDING_CHILD"; then
    if ! "$_XCODE_PENDING_PYTHON" "$_XCODE_PENDING_HELPER" --session "$_XCODE_PENDING_SESSION" --control stop >/dev/null 2>&1; then
      if _xcode_owned_child "$_XCODE_PENDING_CHILD"; then
        kill -TERM "$_XCODE_PENDING_CHILD" 2>/dev/null || true
      fi
    fi
    _xcode_finish_child "$_XCODE_PENDING_CHILD"
  fi
  _xcode_remove_session "${_XCODE_PENDING_SESSION:-}" "${_XCODE_PENDING_PYTHON:-}" "${_XCODE_PENDING_HELPER:-}"
  _XCODE_PENDING_CHILD=''
  _XCODE_PENDING_SESSION=''
  _XCODE_PENDING_PYTHON=''
  _XCODE_PENDING_HELPER=''
}

xcode_bridge_start() {
  local root python helper session child port attempts old_child old_session old_helper old_python launcher_pid
  local -a mounts
  if (( $# < 1 || ($# - 1) % 2 != 0 )); then
    printf '%s\n' 'Xcode: expected ROOT and exact HOST CONTAINER mount pairs.' >&2
    return 2
  fi
  root="$1"
  shift
  mounts=()
  while (( $# > 0 )); do
    mounts+=(--mount "$1" "$2")
    shift 2
  done
  if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Xcode: the host bridge requires macOS.' >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! command -v xcode-select >/dev/null 2>&1 ||
     ! xcode-select -p >/dev/null 2>&1; then
    printf '%s\n' 'Xcode: install Python 3 and select the Xcode developer tools before enabling this option.' >&2
    return 1
  fi
  python="$(command -v python3)"
  helper="$root/scripts/platform/macos/xcode-bridge.py"
  if [[ ! -f "$helper" || -L "$helper" ]]; then
    printf '%s\n' 'Xcode: the shipped bridge helper is unavailable.' >&2
    return 1
  fi
  if ! "$python" "$helper" --session /tmp --validate-map ${mounts[@]+"${mounts[@]}"}; then
    printf '%s\n' 'Xcode: invalid launch mount map.' >&2
    return 2
  fi
  if [[ "${XCODE_BRIDGE_ACTIVE:-0}" == 1 && -n "${_XCODE_CHILD:-}" ]] && _xcode_owned_child "$_XCODE_CHILD"; then
    if "$python" "$helper" --session "$_XCODE_SESSION" --control matches ${mounts[@]+"${mounts[@]}"} &&
       port="$("$python" "$helper" --session "$_XCODE_SESSION" --control health)"; then
      XCODE_BRIDGE_PORT="$port"
      return 0
    fi
  fi
  printf '%s\n' 'Xcode: projects and dependencies can execute build scripts on your host with your user permissions.' >&2
  _XCODE_PENDING_PYTHON="$python"
  _XCODE_PENDING_HELPER="$helper"
  _XCODE_PENDING_CHILD=''
  _XCODE_PENDING_SESSION="$(umask 077; mktemp -d /tmp/codexshell-xcode.XXXXXXXX)" || return 1
  session="$_XCODE_PENDING_SESSION"
  launcher_pid="${BASHPID:-$$}"
  "$python" "$helper" --session "$session" --owner-pid "$launcher_pid" --project-root "$root" ${mounts[@]+"${mounts[@]}"} >"$session/bridge.log" 2>&1 &
  _XCODE_PENDING_CHILD=$!
  child="$_XCODE_PENDING_CHILD"
  attempts=0
  port=''
  while (( attempts < 50 )); do
    if [[ -f "$session/manifest.json" ]] &&
       port="$("$python" "$helper" --session "$session" --control health 2>/dev/null)"; then
      break
    fi
    if ! _xcode_owned_child "$child"; then
      break
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    _xcode_stop_pending
    printf '%s\n' 'Xcode: authenticated bridge startup failed; no container was launched.' >&2
    return 1
  fi
  old_child="${_XCODE_CHILD:-}"
  old_session="${_XCODE_SESSION:-}"
  old_helper="${_XCODE_HELPER:-}"
  old_python="${_XCODE_PYTHON:-}"
  if [[ -n "$old_child" ]] && _xcode_owned_child "$old_child"; then
    "$old_python" "$old_helper" --session "$old_session" --control stop >/dev/null 2>&1 || true
    _xcode_finish_child "$old_child"
  fi
  _xcode_remove_session "$old_session" "$old_python" "$old_helper"
  _XCODE_CHILD="$child"
  _XCODE_SESSION="$session"
  _XCODE_HELPER="$helper"
  _XCODE_PYTHON="$python"
  XCODE_BRIDGE_HOST=host.docker.internal
  XCODE_BRIDGE_PORT="$port"
  XCODE_BRIDGE_ACTIVE=1
  XCODE_DOCKER_ARGS=(-v "$session:/run/codexshell-xcode:ro"
    -e CODEXSHELL_XCODE=1 -e CODEXSHELL_XCODE_HOST=host.docker.internal
    -e "CODEXSHELL_XCODE_PORT=$port")
  _XCODE_PENDING_CHILD=''
  _XCODE_PENDING_SESSION=''
  _XCODE_PENDING_PYTHON=''
  _XCODE_PENDING_HELPER=''
}

xcode_bridge_stop() {
  _xcode_stop_pending
  if [[ -n "${_XCODE_CHILD:-}" ]] && _xcode_owned_child "$_XCODE_CHILD"; then
    "$_XCODE_PYTHON" "$_XCODE_HELPER" --session "$_XCODE_SESSION" --control stop >/dev/null 2>&1 || true
    _xcode_finish_child "$_XCODE_CHILD"
  fi
  _xcode_remove_session "${_XCODE_SESSION:-}"
  _XCODE_CHILD=''
  _XCODE_SESSION=''
  XCODE_BRIDGE_ACTIVE=0
  # shellcheck disable=SC2034 # Public adapter outputs consumed by the launch coordinator.
  XCODE_BRIDGE_HOST=''
  # shellcheck disable=SC2034 # Public adapter outputs consumed by the launch coordinator.
  XCODE_BRIDGE_PORT=''
  # shellcheck disable=SC2034 # Public adapter outputs consumed by the launch coordinator.
  XCODE_DOCKER_ARGS=()
}

xcode_bridge_cleanup() {
  xcode_bridge_stop
}
