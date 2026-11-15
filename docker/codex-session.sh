#!/usr/bin/env bash
set -euo pipefail

if ! codex login status >/dev/null 2>&1; then
  printf '\nCodex authentication is required.\n'
  printf 'Complete the device code sign-in in your browser using the instructions below.\n\n'
  if ! codex login --device-auth; then
    printf '\nCodex authentication failed.\n' >&2
    printf 'Enable device code authentication in ChatGPT Settings > Security, then try again.\n' >&2
    printf 'For managed ChatGPT workspaces, ask your administrator to enable device code authentication.\n' >&2
    exit 1
  fi
  if ! codex login status >/dev/null 2>&1; then
    printf '\nCodex did not report a successful login. Please retry.\n' >&2
    exit 1
  fi
fi

printf '\nLaunching Codex CLI in %s...\n' "$PWD"
printf 'To copy text in macOS Terminal, select it with the mouse and press Command+C.\n'
exec codex --sandbox danger-full-access --no-alt-screen
