#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'login status')
    [[ "$(cat "$MOCK_AUTH")" == yes ]]
    ;;
  'login --device-auth')
    [[ "${MOCK_FAIL_LOGIN:-no}" != yes ]] || exit 1
    [[ "${MOCK_SKIP_MARKER:-no}" != yes ]] || exit 0
    printf 'yes\n' > "$MOCK_AUTH"
    ;;
  '--sandbox danger-full-access --no-alt-screen')
    printf 'Codex started\n'
    ;;
  *) exit 13 ;;
esac
MOCK
chmod +x "$TMP/bin/codex"
export MOCK_LOG="$TMP/log" MOCK_AUTH="$TMP/auth"
printf 'no\n' > "$MOCK_AUTH"
PATH="$TMP/bin:$PATH" bash "$ROOT/docker/codex-session.sh" > "$TMP/output"
grep -Fqx 'login status' "$MOCK_LOG"
grep -Fqx 'login --device-auth' "$MOCK_LOG"
grep -Fqx 'Codex started' "$TMP/output"
grep -Fqx -- '--sandbox danger-full-access --no-alt-screen' "$MOCK_LOG"
grep -Fqx 'yes' "$MOCK_AUTH"
: > "$MOCK_LOG"
PATH="$TMP/bin:$PATH" bash "$ROOT/docker/codex-session.sh" > "$TMP/output"
! grep -Fq 'login --device-auth' "$MOCK_LOG"
grep -Fqx 'Codex started' "$TMP/output"
grep -Fqx -- '--sandbox danger-full-access --no-alt-screen' "$MOCK_LOG"
printf 'no\n' > "$MOCK_AUTH"
: > "$MOCK_LOG"
if MOCK_FAIL_LOGIN=yes PATH="$TMP/bin:$PATH" bash "$ROOT/docker/codex-session.sh" > "$TMP/output" 2>&1; then
  echo 'Expected device login failure to be fatal.' >&2
  exit 1
fi
! grep -Fqx '' "$MOCK_LOG"
! grep -Fqx 'Codex started' "$TMP/output"
grep -Fq 'Enable device code authentication' "$TMP/output"
printf 'no\n' > "$MOCK_AUTH"
: > "$MOCK_LOG"
if MOCK_SKIP_MARKER=yes PATH="$TMP/bin:$PATH" bash "$ROOT/docker/codex-session.sh" > "$TMP/output" 2>&1; then
  echo 'Expected a missing post-login status to be fatal.' >&2
  exit 1
fi
! grep -Fxq 'Codex started' "$TMP/output"
grep -Fq 'did not report a successful login' "$TMP/output"
printf 'All CodexShell authentication tests passed.\n'
