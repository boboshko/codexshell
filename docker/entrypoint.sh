#!/usr/bin/env bash
set -euo pipefail

if [[ "${CODEXSHELL_XCODE:-0}" == 1 ]]; then
  export PATH="/usr/local/lib/codexshell-xcode:$PATH"
fi
if [[ "${FIREWALL_MODE:-enabled}" == enabled ]]; then
  /usr/local/bin/firewall.sh
fi

if [[ "${CODEXSHELL_XCODE:-0}" == 1 ]]; then
  node /usr/local/lib/codexshell-xcode/bridge-client.mjs --health || { printf 'Xcode: container cannot reach the authenticated bridge.\n' >&2; exit 1; }
fi

if [[ "$(id -u)" == 0 ]]; then
  uid="${HOST_UID:-10001}"
  gid="${HOST_GID:-10001}"
  if [[ ! "$uid" =~ ^[1-9][0-9]*$ || ! "$gid" =~ ^[0-9]+$ ]]; then
    printf 'Invalid host user or group ID. Run CodexShell as a non-root user.\n' >&2
    exit 1
  fi
  printf 'Preparing Codex profile for UID %s, GID %s...\n' "$uid" "$gid"
  chown "$uid:$gid" /home/codex /workspace
  chown -R "$uid:$gid" /home/codex/.codex
  if [[ "${CODEXSHELL_DOCKER_SOCKET:-0}" == 1 ]]; then
    [[ -S /var/run/docker.sock ]] || { printf 'Tools: Docker socket is unavailable.\n' >&2; exit 1; }
    socket_gid=$(stat -c '%g' /var/run/docker.sock)
    [[ "$socket_gid" =~ ^[0-9]+$ ]] || { printf 'Tools: invalid socket group.\n' >&2; exit 1; }
    exec setpriv --reuid "$uid" --regid "$gid" --groups "$socket_gid" env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh
  fi
  exec gosu "$uid:$gid" env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh
fi

exec env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh
