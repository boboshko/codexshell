#!/usr/bin/env bash

_tools_error() { TOOLS_MESSAGE=$*; printf 'Tools: %s\n' "$*" >&2; return 2; }
_tools_index() {
  local i=0 slug
  for slug in ${TOOLS_SLUGS[@]+"${TOOLS_SLUGS[@]}"}; do
    if [[ "$slug" == "$1" ]]; then TOOLS_INDEX=$i; return 0; fi
    i=$((i+1))
  done
  return 2
}
tools_enabled() { _tools_index "$1" || return 2; [[ "${TOOLS_VALUES[$TOOLS_INDEX]}" == on ]]; }
tools_get() { _tools_index "$1" || return 2; printf '%s\n' "${TOOLS_VALUES[$TOOLS_INDEX]}"; }
_tools_validate() {
  local i dep
  [[ "${TOOLS_SLUGS[0]+present}" == present ]] || { _tools_error 'empty catalog'; return 2; }
  for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
    [[ "${TOOLS_VALUES[$i]}" == on || "${TOOLS_VALUES[$i]}" == off ]] || { _tools_error 'invalid staged value'; return 2; }
    [[ "${TOOLS_VALUES[$i]}" == on ]] || continue
    if [[ "${TOOLS_PLATFORMS[$i]}" == macos && "$(uname -s)" != Darwin ]]; then _tools_error 'Xcode requires macOS'; return 2; fi
    if [[ "${TOOLS_REQUIRES[$i]}" != - ]]; then
      local -a dependencies=()
      IFS=, read -r -a dependencies <<< "${TOOLS_REQUIRES[$i]}"
      for dep in "${dependencies[@]}"; do
        tools_enabled "$dep" || { _tools_error "${TOOLS_SLUGS[$i]} requires $dep"; return 2; }
      done
    fi
  done
}
tools_load() {
  local root=$1 slug group label kind platform requires extra line key value i
  local -a seen=()
  TOOLS_SLUGS=() TOOLS_GROUPS=() TOOLS_LABELS=() TOOLS_KINDS=() TOOLS_PLATFORMS=() TOOLS_REQUIRES=() TOOLS_VALUES=()
  [[ -f "$root/scripts/tools-catalog.tsv" && ! -L "$root/scripts/tools-catalog.tsv" ]] || { _tools_error 'missing catalog'; return 2; }
  while IFS=$'\t' read -r slug group label kind platform requires extra || [[ -n "$slug" ]]; do
    [[ "$slug" =~ ^[A-Z][A-Z0-9_]*$ && -n "$group" && -n "$label" && -n "$requires" && -z "$extra" ]] || { _tools_error 'invalid catalog row'; return 2; }
    case "$kind:$platform" in image:all|runtime:all|runtime:macos|image:macos) ;; *) _tools_error 'invalid catalog metadata'; return 2 ;; esac
    if _tools_index "$slug"; then _tools_error 'duplicate catalog slug'; return 2; fi
    TOOLS_SLUGS+=("$slug") TOOLS_GROUPS+=("$group") TOOLS_LABELS+=("$label") TOOLS_KINDS+=("$kind") TOOLS_PLATFORMS+=("$platform") TOOLS_REQUIRES+=("$requires") TOOLS_VALUES+=(off)
  done < "$root/scripts/tools-catalog.tsv"
  [[ "${TOOLS_SLUGS[0]+present}" == present ]] || { _tools_error 'empty catalog'; return 2; }
  for requires in "${TOOLS_REQUIRES[@]}"; do
    [[ "$requires" == - ]] && continue
    [[ "$requires" =~ ^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$ ]] || { _tools_error 'invalid catalog dependency'; return 2; }
    local -a deps=()
    IFS=, read -r -a deps <<< "$requires"
    for key in "${deps[@]}"; do _tools_index "$key" || { _tools_error 'unknown catalog dependency'; return 2; }; done
  done
  [[ ! -L "$root/config" && ( ! -e "$root/config" || -d "$root/config" ) ]] || { _tools_error 'unsafe config directory'; return 2; }
  [[ ! -L "$root/config/tools.conf" ]] || { _tools_error 'unsafe tools.conf'; return 2; }
  [[ -e "$root/config/tools.conf" ]] || return 0
  [[ -f "$root/config/tools.conf" ]] || { _tools_error 'tools.conf is not regular'; return 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^TOOL_([A-Z][A-Z0-9_]*)=(on|off)$ ]] || { _tools_error 'malformed tools.conf row'; return 2; }
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    _tools_index "$key" || { _tools_error "unknown setting $key"; return 2; }
    i=$TOOLS_INDEX
    [[ "${seen[$i]:-}" != 1 ]] || { _tools_error "duplicate setting $key"; return 2; }
    seen[$i]=1 TOOLS_VALUES[$i]=$value
  done < "$root/config/tools.conf"
  _tools_validate
}
tools_set() {
  local slug=$1 value=$2 index dep
  [[ "$value" == on || "$value" == off ]] || return 2
  _tools_index "$slug" || return 2
  index=$TOOLS_INDEX
  if [[ "$slug" == PYTHON && "$value" == off ]] && tools_enabled UV; then _tools_error 'disable uv before Python'; return 2; fi
  if [[ "$value" == on && "${TOOLS_PLATFORMS[$index]}" == macos && "$(uname -s)" != Darwin ]]; then _tools_error 'Xcode requires macOS'; return 2; fi
  if [[ "$value" == on && "${TOOLS_REQUIRES[$index]}" != - ]]; then
    local -a deps=()
    IFS=, read -r -a deps <<< "${TOOLS_REQUIRES[$index]}"
    for dep in "${deps[@]}"; do
      _tools_index "$dep" || return 2
      TOOLS_VALUES[$TOOLS_INDEX]=on
      TOOLS_MESSAGE="$slug also enables $dep."
      printf 'Tools: %s\n' "$TOOLS_MESSAGE" >&2
    done
  fi
  TOOLS_VALUES[$index]=$value
}
tools_cleanup() {
  if [[ -n "${TOOLS_TEMP:-}" ]]; then rm -f -- "$TOOLS_TEMP"; TOOLS_TEMP=''; fi
  if [[ -n "${TOOLS_LOCK:-}" ]]; then rmdir -- "$TOOLS_LOCK" 2>/dev/null || true; TOOLS_LOCK=''; fi
}
tools_save() {
  local root=$1 i
  _tools_validate || return 2
  [[ ! -L "$root/config" && ( ! -e "$root/config" || -d "$root/config" ) && ! -L "$root/config/tools.conf" && ( ! -e "$root/config/tools.conf" || -f "$root/config/tools.conf" ) ]] || { _tools_error 'unsafe configuration destination'; return 2; }
  if ! mkdir -- "$root/.codexshell-update.lock" 2>/dev/null; then _tools_error 'update or settings operation in progress'; return 1; fi
  TOOLS_LOCK=$root/.codexshell-update.lock
  if ! (umask 077; mkdir -p -- "$root/config"); then tools_cleanup; return 1; fi
  TOOLS_TEMP=$(umask 077; mktemp "$root/config/.tools.XXXXXXXX") || { tools_cleanup; return 1; }
  for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
    if ! printf 'TOOL_%s=%s\n' "${TOOLS_SLUGS[$i]}" "${TOOLS_VALUES[$i]}" >> "$TOOLS_TEMP"; then tools_cleanup; return 1; fi
  done
  if ! mv -f -- "$TOOLS_TEMP" "$root/config/tools.conf"; then tools_cleanup; return 1; fi
  TOOLS_TEMP=''
  tools_cleanup
}
tools_build_args() {
  local i value
  TOOLS_BUILD_ARGS=()
  _tools_validate || return 2
  for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
    [[ "${TOOLS_KINDS[$i]}" == image ]] || continue
    value=0
    [[ "${TOOLS_VALUES[$i]}" == off ]] || value=1
    TOOLS_BUILD_ARGS+=(--build-arg "TOOL_${TOOLS_SLUGS[$i]}=$value")
  done
}
_tools_toggle() {
  local root=$1 slug=$2 reply value=on
  TOOLS_MESSAGE=''
  if tools_enabled "$slug"; then value=off; fi
  if [[ "$slug:$value" == DOCKER_SOCKET:on ]]; then
    menu_cleanup
    printf 'Tools: Docker socket access grants root-equivalent control of the host.\nEnable? [y/N]: ' >&2
    IFS= read -r reply || return 0
    [[ "$reply" == y ]] || { TOOLS_MESSAGE='Docker socket access remains disabled.'; return 0; }
  fi
  if [[ "$slug:$value" == XCODE:on ]]; then
    menu_cleanup
    printf 'Tools: Xcode projects may execute build scripts on the host.\n' >&2
    if ! declare -F start_xcode_for_mounts >/dev/null; then _tools_error 'Xcode launch adapter is unavailable'; return 1; fi
    start_xcode_for_mounts "$root" || { TOOLS_MESSAGE='Xcode bridge could not be enabled.'; return 1; }
  fi
  tools_set "$slug" "$value"
}
tools_manage() {
  local root=$1 status=0 before_active=${XCODE_BRIDGE_ACTIVE:-0}
  TOOLS_MESSAGE=''
  tools_load "$root" || return 2
  local -a before=("${TOOLS_VALUES[@]}")
  if menu_tools "$root"; then
    if tools_save "$root"; then
      if ! tools_enabled XCODE && [[ "${XCODE_BRIDGE_ACTIVE:-0}" == 1 ]]; then xcode_bridge_stop; fi
      return 0
    fi
    printf 'Tools: could not save settings; committed configuration is unchanged.\n' >&2
    status=1
  else
    status=$?
  fi
  menu_cleanup
  TOOLS_VALUES=("${before[@]}")
  if [[ "$before_active" == 0 && "${XCODE_BRIDGE_ACTIVE:-0}" == 1 ]]; then xcode_bridge_stop || true; fi
  return "$status"
}

tools_socket_path() {
  local endpoint
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}') || { _tools_error 'cannot inspect selected Docker context'; return 1; }
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint=$DOCKER_HOST
  else
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') || { _tools_error 'cannot inspect current Docker context'; return 1; }
  fi
  case "$endpoint" in
    unix:///*) TOOLS_SOCKET_PATH=${endpoint#unix://} ;;
    *) _tools_error 'socket access requires a local Unix-socket Docker endpoint'; return 2 ;;
  esac
  [[ -S "$TOOLS_SOCKET_PATH" && "$TOOLS_SOCKET_PATH" != *$'\n'* && "$TOOLS_SOCKET_PATH" != *$'\r'* && "$TOOLS_SOCKET_PATH" != *,* ]] || { _tools_error 'selected Docker socket is unavailable or has an unsupported path'; return 2; }
}
