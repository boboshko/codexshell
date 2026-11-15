#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-version.sh
source "$ROOT/scripts/lib-version.sh"
case "${1:-}" in
  --help|-h)
    (( $# == 1 )) || { printf 'Usage: start.sh [--version|--help]\n' >&2; exit 2; }
    printf 'Usage: start.sh [--version|--help]\nSet CODEXSHELL_NO_UPDATE_CHECK=1 to skip release checks.\n'
    exit 0
    ;;
  --version)
    (( $# == 1 )) || { printf 'Usage: start.sh [--version|--help]\n' >&2; exit 2; }
    version_read "$ROOT" || { printf 'Cannot read a valid VERSION file.\n' >&2; exit 1; }
    exit 0
    ;;
  '') (( $# == 0 )) || { printf 'Usage: start.sh [--version|--help]\n' >&2; exit 2; } ;;
  *) printf 'Usage: start.sh [--version|--help]\n' >&2; exit 2 ;;
esac
version="$(version_read "$ROOT")" || { printf 'Cannot read a valid VERSION file.\n' >&2; exit 1; }
# shellcheck source=scripts/lib-menu.sh
source "$ROOT/scripts/lib-menu.sh"
# shellcheck source=scripts/lib-update.sh
source "$ROOT/scripts/lib-update.sh"
# shellcheck source=scripts/lib-tools.sh
source "$ROOT/scripts/lib-tools.sh"
# shellcheck source=scripts/lib-build.sh
source "$ROOT/scripts/lib-build.sh"
FOLDER_TEMP=''
cleanup() {
  menu_cleanup
  tools_cleanup
  build_cleanup
  if declare -F xcode_bridge_cleanup >/dev/null; then xcode_bridge_cleanup || true; fi
  if [[ -n "$FOLDER_TEMP" ]]; then rm -f -- "$FOLDER_TEMP"; FOLDER_TEMP=''; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
[[ ! -L "$ROOT/config" && ( ! -e "$ROOT/config" || -d "$ROOT/config" ) ]] || { printf 'Unsafe configuration directory.\n' >&2; exit 2; }
mkdir -p "$ROOT/config"
[[ -f "$ROOT/config/folders.txt" ]] || : > "$ROOT/config/folders.txt"
[[ -f "$ROOT/config/firewall" ]] || printf 'enabled\n' > "$ROOT/config/firewall"
UPDATE_TAG=''
UPDATE_VERSION=''
if [[ "${CODEXSHELL_NO_UPDATE_CHECK:-}" != 1 ]]; then update_check "$ROOT" "$version"; fi
reset_mount_targets() {
  MOUNT_COUNT=0
  MOUNT_DESTINATIONS=()
}
next_mount_target() {
  local basename="${1##*/}" candidate collision n=1 j
  while true; do
    candidate="/workspace/$basename"
    if (( n > 1 )); then candidate="${candidate}-$n"; fi
    collision=0
    for (( j=0; j<MOUNT_COUNT; j++ )); do
      if [[ "${MOUNT_DESTINATIONS[$j]}" == "$candidate" ]]; then collision=1; break; fi
    done
    if (( collision == 0 )); then break; fi
    n=$((n+1))
  done
  MOUNT_DESTINATIONS[MOUNT_COUNT]="$candidate"
  MOUNT_COUNT=$((MOUNT_COUNT+1))
  MOUNT_TARGET="$candidate"
}
pause() { IFS= read -r -p 'Press Enter to continue...' _ || true; }
folders() {
  local n path title line
  while true; do
    title='Mounted folders:'
    n=0
    reset_mount_targets
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "$path" ]] || continue
      n=$((n+1))
      if [[ -d "$path" ]]; then
        next_mount_target "$path"
        printf -v line '%s. %s -> %s' "$n" "$path" "$MOUNT_TARGET"
      else
        printf -v line '%s. %s (missing)' "$n" "$path"
      fi
      title="$title"$'\n'"$line"
    done < "$ROOT/config/folders.txt"
    if ! menu_select "$title" 1 'Add folder' 2 'Remove folder' 0 'Back'; then exit 0; fi
    case "$MENU_KEY" in
      1)
        IFS= read -r -p 'Absolute local folder path: ' path || exit 0
        [[ "$path" == /* && -d "$path" ]] || { printf 'Folder does not exist or path is not absolute.\n'; pause; continue; }
        path="$(cd "$path" && pwd -P)" || { printf 'Cannot access folder.\n' >&2; pause; continue; }
        [[ "$path" != / ]] || { printf 'Mounting the filesystem root is not allowed.\n'; pause; continue; }
        [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || { printf 'Folder paths cannot contain line breaks.\n'; pause; continue; }
        if grep -Fxq -- "$path" "$ROOT/config/folders.txt"; then printf 'Already mounted.\n'; else printf '%s\n' "$path" >> "$ROOT/config/folders.txt"; fi
        ;;
      2)
        IFS= read -r -p 'Folder number to remove: ' n || exit 0
        [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
        FOLDER_TEMP="$(mktemp "$ROOT/config/.folders.XXXXXXXX")"
        if ! awk -v target="$n" 'NF {i++; if(i!=target) print}' "$ROOT/config/folders.txt" > "$FOLDER_TEMP"; then
          printf 'Cannot prepare folder configuration.\n' >&2
          rm -f -- "$FOLDER_TEMP"
          FOLDER_TEMP=''
          continue
        fi
        mv -- "$FOLDER_TEMP" "$ROOT/config/folders.txt"
        FOLDER_TEMP=''
        ;;
      0) return ;;
    esac
  done
}
firewall() {
  while true; do
    if ! menu_select "Firewall: $(cat "$ROOT/config/firewall")" 1 'Enable' 2 'Disable' 3 'View allowed domains' 0 'Back'; then exit 0; fi
    case "$MENU_KEY" in
      1) printf 'enabled\n' > "$ROOT/config/firewall" ;;
      2) printf 'disabled\n' > "$ROOT/config/firewall" ;;
      3) cat "$ROOT/docker/allowed-domains.txt"; pause ;;
      0) return ;;
    esac
  done
}
start_xcode_for_mounts() {
  local root=$1 path
  local -a mapping=()
  [[ "$(uname -s)" == Darwin ]] || { printf 'Xcode: macOS is required.\n' >&2; return 2; }
  # shellcheck source=scripts/platform/macos/lib-xcode-bridge.sh
  source "$root/scripts/platform/macos/lib-xcode-bridge.sh"
  reset_mount_targets
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" && -d "$path" ]] || continue
    next_mount_target "$path"
    mapping+=("$path" "$MOUNT_TARGET")
  done < "$root/config/folders.txt"
  xcode_bridge_start "$root" ${mapping[@]+"${mapping[@]}"}
}
launch() {
  command -v docker >/dev/null || { printf 'Docker is required.\n'; pause; return; }
  docker info >/dev/null 2>&1 || { printf 'Docker daemon is not running or is inaccessible.\n'; pause; return; }
  local -a mounts=() args=()
  tools_load "$ROOT" || { pause; return; }
  local path i=0
  reset_mount_targets
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    [[ -d "$path" ]] || { printf 'Skipping missing folder: %s\n' "$path"; continue; }
    next_mount_target "$path"
    i=$((i+1))
    mounts+=(--mount "type=bind,source=$path,target=$MOUNT_TARGET")
    printf 'Mounted: %s -> %s\n' "$path" "$MOUNT_TARGET"
  done < "$ROOT/config/folders.txt"
  if (( i == 0 )); then printf 'No local folders are mounted.\n'; fi
  local mode
  mode="$(cat "$ROOT/config/firewall")"
  [[ "$mode" == enabled || "$mode" == disabled ]] || { printf 'Invalid firewall configuration.\n'; return; }
  build_ensure "$ROOT" "$version" || { pause; return; }
  if tools_enabled XCODE; then start_xcode_for_mounts "$ROOT" || { pause; return; }; fi
  args=(run --rm -it --init --name "codexshell-$$" --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --pids-limit 512 --memory 8g --mount 'type=volume,source=codexshell-home,target=/home/codex/.codex' --env "FIREWALL_MODE=$mode" --env "HOST_UID=$(id -u)" --env "HOST_GID=$(id -g)")
  if [[ "$mode" == enabled ]]; then args+=(--cap-add NET_ADMIN); fi
  if tools_enabled DOCKER_SOCKET; then
    tools_socket_path || { pause; return; }
    args+=(--mount "type=bind,source=$TOOLS_SOCKET_PATH,target=/var/run/docker.sock" --env CODEXSHELL_DOCKER_SOCKET=1)
  fi
  local tool_index enabled_tools=''
  for ((tool_index=0; tool_index<${#TOOLS_SLUGS[@]}; tool_index++)); do
    if [[ "${TOOLS_VALUES[$tool_index]}" == on ]]; then enabled_tools="${enabled_tools}${TOOLS_SLUGS[$tool_index]},"; fi
  done
  args+=(--env "CODEXSHELL_ENABLED_TOOLS=$enabled_tools")
  if tools_enabled XCODE; then
    args+=("${XCODE_DOCKER_ARGS[@]}")
  fi
  if (( i > 0 )); then args+=("${mounts[@]}"); fi
  args+=(--workdir /workspace codexshell:local)
  printf 'Codex working directory: /workspace\n'
  printf 'Starting Codex (firewall: %s)...\n' "$mode"
  docker "${args[@]}" || { printf 'Codex session ended with an error.\n'; pause; }
}
while true; do
  main_options=(1 'Launch Codex' 2 'Manage folders' 3 "Firewall ($(cat "$ROOT/config/firewall"))" 5 'Tools')
  if [[ -n "$UPDATE_TAG" ]] && version_is_newer "$UPDATE_TAG" "$version"; then
    main_options+=(4 "Update to $UPDATE_VERSION")
  fi
  main_options+=(0 'Exit')
  if ! menu_select "CodexShell $version" "${main_options[@]}"; then exit 0; fi
  case "$MENU_KEY" in
    1) launch ;;
    2) folders ;;
    3) firewall ;;
    5)
      if tools_manage "$ROOT"; then :; else
        tools_status=$?
        if ((tools_status==1 || tools_status==2)); then pause; fi
      fi
      ;;
    4)
      if update_install "$ROOT" "$UPDATE_TAG"; then
        cleanup
        exec "$ROOT/start.sh"
      else
        printf 'Update failed. See the installer error above.\n' >&2
        pause
      fi
      ;;
    0) exit 0 ;;
  esac
done
