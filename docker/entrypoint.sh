#!/usr/bin/env bash
set -euo pipefail

if [[ "${FIREWALL_MODE:-enabled}" == enabled ]]; then
  /usr/local/bin/firewall.sh
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
  exec gosu "$uid:$gid" env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh
fi

exec env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh
