#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/app/config" "$TMP/app/docker" "$TMP/project with spaces"
cp "$ROOT/start.sh" "$TMP/app/start.sh"
cp "$ROOT/VERSION" "$TMP/app/VERSION"
cp -R "$ROOT/scripts" "$TMP/app/scripts"
cp "$ROOT/docker/allowed-domains.txt" "$TMP/app/docker/allowed-domains.txt"
printf 'enabled\n' > "$TMP/app/config/firewall"
: > "$TMP/app/config/folders.txt"
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  build) printf '%s\n' "$@" > "$TEST_BUILD_ARGS" ;;
  run) printf '%s\n' "$@" > "$TEST_RUN_ARGS" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin/docker"
export TEST_RUN_ARGS="$TMP/run.args" TEST_BUILD_ARGS="$TMP/build.args" CODEXSHELL_NO_UPDATE_CHECK=1
printf '1\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fqx -- 'run' "$TEST_RUN_ARGS"
grep -Fqx -- 'CHOWN' "$TEST_RUN_ARGS"
grep -Fqx -- 'DAC_OVERRIDE' "$TEST_RUN_ARGS"
grep -Fqx -- 'SETUID' "$TEST_RUN_ARGS"
grep -Fqx -- 'SETGID' "$TEST_RUN_ARGS"
grep -Fqx -- 'NET_ADMIN' "$TEST_RUN_ARGS"
grep -Fqx -- 'type=volume,source=codexshell-home,target=/home/codex/.codex' "$TEST_RUN_ARGS"
grep -Fqx -- '--progress=plain' "$TEST_BUILD_ARGS"
grep -Fqx -- '--build-arg' "$TEST_BUILD_ARGS"
grep -Fqx -- "APP_VERSION=$(cat "$ROOT/VERSION")" "$TEST_BUILD_ARGS"
! grep -Fq -- 'type=bind' "$TEST_RUN_ARGS"
grep -Fqx -- '--workdir' "$TEST_RUN_ARGS"
grep -Fqx -- '/workspace' "$TEST_RUN_ARGS"
printf '%s\n' "$TMP/project with spaces" > "$TMP/app/config/folders.txt"
printf 'disabled\n' > "$TMP/app/config/firewall"
printf '1\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fqx -- "type=bind,source=$TMP/project with spaces,target=/workspace/project with spaces" "$TEST_RUN_ARGS"
grep -Fqx -- '/workspace' "$TEST_RUN_ARGS"
grep -Fq -- "Mounted: $TMP/project with spaces -> /workspace/project with spaces" "$TMP/output"
grep -Fq -- 'Codex working directory: /workspace' "$TMP/output"
! grep -Fq -- 'NET_ADMIN' "$TEST_RUN_ARGS"
mkdir -p "$TMP/second project"
printf '%s\n%s\n' "$TMP/project with spaces" "$TMP/second project" > "$TMP/app/config/folders.txt"
printf '1\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fqx -- "type=bind,source=$TMP/project with spaces,target=/workspace/project with spaces" "$TEST_RUN_ARGS"
grep -Fqx -- "type=bind,source=$TMP/second project,target=/workspace/second project" "$TEST_RUN_ARGS"
grep -Fqx -- '/workspace' "$TEST_RUN_ARGS"
grep -Fq -- "Mounted: $TMP/second project -> /workspace/second project" "$TMP/output"
printf '%s\n' "$TMP/nonexistent" "$TMP/second project" > "$TMP/app/config/folders.txt"
printf '1\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fq -- "Skipping missing folder: $TMP/nonexistent" "$TMP/output"
grep -Fqx -- "type=bind,source=$TMP/second project,target=/workspace/second project" "$TEST_RUN_ARGS"
grep -Fqx -- '/workspace' "$TEST_RUN_ARGS"
mkdir -p "$TMP/another/project with spaces"
printf '%s\n%s\n' "$TMP/project with spaces" "$TMP/another/project with spaces" > "$TMP/app/config/folders.txt"
printf '1\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fqx -- "type=bind,source=$TMP/project with spaces,target=/workspace/project with spaces" "$TEST_RUN_ARGS"
grep -Fqx -- "type=bind,source=$TMP/another/project with spaces,target=/workspace/project with spaces-2" "$TEST_RUN_ARGS"
grep -Fq -- "Mounted: $TMP/another/project with spaces -> /workspace/project with spaces-2" "$TMP/output"
grep -Fqx -- '/workspace' "$TEST_RUN_ARGS"
printf '2\n0\n0\n' | PATH="$TMP/bin:$PATH" bash "$TMP/app/start.sh" > "$TMP/output"
grep -Fq -- "$TMP/another/project with spaces -> /workspace/project with spaces-2" "$TMP/output"
cat > "$TMP/bin/chown" <<'MOCK'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "$TEST_ENTRY_LOG"
MOCK
cat > "$TMP/bin/id" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -u) printf '0\n' ;;
  -g) printf '20\n' ;;
  *) exit 1 ;;
esac
MOCK
cat > "$TMP/bin/gosu" <<'MOCK'
#!/usr/bin/env bash
printf 'gosu %s\n' "$*" >> "$TEST_ENTRY_LOG"
MOCK
chmod +x "$TMP/bin/chown" "$TMP/bin/gosu" "$TMP/bin/id"
export TEST_ENTRY_LOG="$TMP/entry.log"
HOST_UID=501 HOST_GID=20 FIREWALL_MODE=disabled PATH="$TMP/bin:$PATH" bash "$ROOT/docker/entrypoint.sh"
grep -Fqx -- 'chown 501:20 /home/codex /workspace' "$TEST_ENTRY_LOG"
grep -Fqx -- 'chown -R 501:20 /home/codex/.codex' "$TEST_ENTRY_LOG"
grep -Fqx -- 'gosu 501:20 env HOME=/home/codex CODEX_HOME=/home/codex/.codex /usr/local/bin/codex-session.sh' "$TEST_ENTRY_LOG"
if HOST_UID=0 HOST_GID=20 FIREWALL_MODE=disabled PATH="$TMP/bin:$PATH" bash "$ROOT/docker/entrypoint.sh" > /dev/null 2>&1; then
  printf 'Invalid UID was unexpectedly accepted.\n' >&2
  exit 1
fi
grep -Eq '(^|[[:space:]])procps([[:space:]]|$)' "$ROOT/docker/Dockerfile"
grep -Fq -- 'command -v ps' "$ROOT/docker/Dockerfile"
grep -Fq -- 'COPY codex-session.sh /usr/local/bin/codex-session.sh' "$ROOT/docker/Dockerfile"
grep -Fq -- 'exec codex --sandbox danger-full-access --no-alt-screen' "$ROOT/docker/codex-session.sh"
printf 'All CodexShell regression tests passed.\n'
