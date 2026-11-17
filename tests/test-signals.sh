#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/signal-session.sh"
TEST_TEMP=''
CURRENT_CONTAINER=''
CURRENT_CONTAINER_ID=''
CURRENT_OWNER=''
RUNNER_PID=''
CURRENT_LOG=''
DOCKER_SOURCE_ROOT=''

valid_container_name() {
  [[ "$1" =~ ^codexshell-signal-(sigint|sigterm)-[0-9]+-[0-9]+$ ]]
}

valid_container_id() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

valid_owner() {
  [[ "$1" =~ ^codexshell-signal-owner-(sigint|sigterm)-[0-9]+-[0-9]+$ ]]
}

container_is_owned() {
  local identity
  valid_container_id "$CURRENT_CONTAINER_ID" || return 1
  valid_container_name "$CURRENT_CONTAINER" || return 1
  valid_owner "$CURRENT_OWNER" || return 1
  identity="$(docker inspect --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.codexshell.signal-owner"}}' "$CURRENT_CONTAINER_ID" 2>/dev/null)" || return 1
  [[ "$identity" == "$CURRENT_CONTAINER_ID|/$CURRENT_CONTAINER|$CURRENT_OWNER" ]]
}

reap_runner_bounded() {
  local deadline
  [[ -n "$RUNNER_PID" ]] || return 0
  deadline=$((SECONDS + 5))
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
  wait "$RUNNER_PID" 2>/dev/null || true
  RUNNER_PID=''
}

cleanup() {
  local runner_reaped=1
  if [[ -n "$CURRENT_CONTAINER_ID" ]] && container_is_owned; then
    docker rm -f "$CURRENT_CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  reap_runner_bounded || runner_reaped=0
  if (( runner_reaped == 1 )) && [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" && "${TEST_TEMP##*/}" == codexshell-signals.* ]]; then
    rm -rf -- "$TEST_TEMP"
  fi
}

handle_int() {
  cleanup
  trap - EXIT
  exit 130
}

handle_term() {
  cleanup
  trap - EXIT
  exit 143
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    printf '%s\n' '--- current Docker output ---' >&2
    sed -n '1,240p' "$CURRENT_LOG" >&2
  fi
  if [[ -n "$CURRENT_LOG" && -f "${CURRENT_LOG%/*}/docker.inspect" ]]; then
    printf '%s\n' '--- current Docker inspection ---' >&2
    sed -n '1,240p' "${CURRENT_LOG%/*}/docker.inspect" >&2
  fi
  if [[ -n "$CURRENT_LOG" && -f "${CURRENT_LOG%/*}/docker.status" ]]; then
    printf '%s' 'Docker status: ' >&2
    sed -n '1p' "${CURRENT_LOG%/*}/docker.status" >&2
  fi
  exit 1
}

wait_for_file() {
  local file=$1 deadline=$2
  while [[ ! -f "$file" ]]; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
}

wait_for_removal() {
  local id=$1 deadline=$2
  while docker inspect "$id" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
}

assert_line_count() {
  local expected=$1 value=$2 file=$3 actual
  actual="$(awk -v value="$value" '$0 == value { count++ } END { print count + 0 }' "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected $expected occurrence(s) of '$value' in $file, got $actual"
}

assert_prefix_count() {
  local expected=$1 prefix=$2 file=$3 actual
  actual="$(awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected $expected '$prefix' line(s) in $file, got $actual"
}

resolve_docker_source_root() {
  local mount_source host_base host_subpath
  DOCKER_SOURCE_ROOT=$ROOT
  if command -v findmnt >/dev/null 2>&1; then
    mount_source="$(findmnt -T "$ROOT" -n -o SOURCE 2>/dev/null || true)"
    case "$mount_source" in
      /run/host_mark/*'['*']')
        host_base=${mount_source%%\[*}
        host_base=${host_base#/run/host_mark}
        host_subpath=${mount_source#*\[}
        host_subpath=${host_subpath%\]}
        DOCKER_SOURCE_ROOT="${host_base}${host_subpath}"
        ;;
    esac
  fi
  [[ "$DOCKER_SOURCE_ROOT" == /* && "$DOCKER_SOURCE_ROOT" != *','* && "$DOCKER_SOURCE_ROOT" != *$'\n'* ]] || fail 'Cannot derive a safe Docker-visible project path.'
}

trap cleanup EXIT
trap handle_int INT
trap handle_term TERM

command -v docker >/dev/null 2>&1 || fail 'Docker CLI is required for the signal integration test.'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable or inaccessible.'
[[ "$(id -u)" != 0 ]] || fail 'The signal integration test requires a non-root host user.'
[[ -x "$FIXTURE" ]] || fail "Signal fixture is not executable: $FIXTURE"

image_id="$(docker image inspect --format '{{.Id}}' codexshell:local 2>/dev/null)" || fail 'Verified local image codexshell:local is required; the test does not build or pull it.'
[[ "$image_id" == sha256:* ]] || fail 'codexshell:local returned an invalid image ID.'
docker_versions="$(docker version --format 'client={{.Client.Version}} server={{.Server.Version}}')" || fail 'Cannot read Docker client/server versions.'
resolve_docker_source_root
TEST_TEMP="$(mktemp -d "$ROOT/tests/codexshell-signals.XXXXXXXX")"
[[ "${TEST_TEMP##*/}" == codexshell-signals.* ]] || fail 'Unexpected temporary directory name.'

printf 'HOST_ARCH=%s\n' "$(uname -m)"
printf 'DOCKER_VERSION=%s\n' "$docker_versions"
printf 'IMAGE_ID=%s\n' "$image_id"

test_name_collision_safety() {
  local attempted_owner created_id
  CURRENT_CONTAINER="codexshell-signal-sigint-$$-${RANDOM}"
  CURRENT_OWNER="codexshell-signal-owner-sigint-$$-${RANDOM}"
  attempted_owner="codexshell-signal-owner-sigint-$$-${RANDOM}"
  valid_container_name "$CURRENT_CONTAINER" || fail 'Generated an unsafe collision-test name.'
  valid_owner "$CURRENT_OWNER" || fail 'Generated an unsafe collision-test owner.'
  valid_owner "$attempted_owner" || fail 'Generated an unsafe attempted owner.'
  created_id="$(docker create --rm --name "$CURRENT_CONTAINER" --label "com.codexshell.signal-owner=$CURRENT_OWNER" --pull never codexshell:local)" || fail 'Could not create the collision-test container.'
  valid_container_id "$created_id" || fail 'Collision-test create returned an invalid container ID.'
  CURRENT_CONTAINER_ID=$created_id
  container_is_owned || fail 'Collision-test ownership validation failed.'
  if docker create --rm --name "$CURRENT_CONTAINER" --label "com.codexshell.signal-owner=$attempted_owner" --pull never codexshell:local > "$TEST_TEMP/collision.stdout" 2> "$TEST_TEMP/collision.stderr"; then
    fail 'Docker unexpectedly allowed a colliding container name.'
  fi
  container_is_owned || fail 'A failed name collision changed or removed the existing container.'
  docker rm "$CURRENT_CONTAINER_ID" >/dev/null || fail 'Could not remove the owned collision-test container by ID.'
  printf 'NAME_COLLISION_RESULT=PASS\n'
  CURRENT_CONTAINER_ID=''
  CURRENT_CONTAINER=''
  CURRENT_OWNER=''
}

run_case() {
  local case_name=$1 expected_signal=$2 expected_status=$3
  local case_dir docker_case_dir docker_home_dir docker_fixture status_file status_temp inspect_file command_file deadline signal_started elapsed docker_status created_id live_pid1_exe
  case_dir="$TEST_TEMP/$case_name"
  docker_case_dir="$DOCKER_SOURCE_ROOT/${case_dir#"$ROOT"/}"
  docker_home_dir="$docker_case_dir/codex-home"
  docker_fixture="$DOCKER_SOURCE_ROOT/${FIXTURE#"$ROOT"/}"
  mkdir -m 700 -- "$case_dir"
  mkdir -m 700 -- "$case_dir/codex-home"
  status_file="$case_dir/docker.status"
  status_temp="$case_dir/.docker.status"
  inspect_file="$case_dir/docker.inspect"
  command_file="$case_dir/signal-command.log"
  CURRENT_LOG="$case_dir/docker.log"
  CURRENT_CONTAINER="codexshell-signal-${case_name}-$$-${RANDOM}"
  CURRENT_OWNER="codexshell-signal-owner-${case_name}-$$-${RANDOM}"
  valid_container_name "$CURRENT_CONTAINER" || fail "Refusing unsafe container name: $CURRENT_CONTAINER"
  valid_owner "$CURRENT_OWNER" || fail "Refusing unsafe ownership label: $CURRENT_OWNER"

  created_id=''
  if ! created_id="$(docker create --rm --init --name "$CURRENT_CONTAINER" \
    --label "com.codexshell.signal-owner=$CURRENT_OWNER" \
    --pull never --network none \
    --cap-drop ALL \
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add KILL --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges --pids-limit 512 --memory 8g \
    --env FIREWALL_MODE=disabled --env "HOST_UID=$(id -u)" --env "HOST_GID=$(id -g)" \
    --mount "type=bind,source=$docker_home_dir,target=/home/codex/.codex" \
    --mount "type=bind,source=$docker_case_dir,target=/workspace" \
    --mount "type=bind,source=$docker_fixture,target=/usr/local/bin/codex-session.sh,readonly" \
    --workdir /workspace codexshell:local 2> "$case_dir/docker-create.log")"; then
    fail "$case_name Docker create failed; no container was acquired or removed."
  fi
  valid_container_id "$created_id" || fail "$case_name Docker create returned an invalid container ID."
  CURRENT_CONTAINER_ID=$created_id
  container_is_owned || fail "$case_name container ownership validation failed."

  (
    run_status=0
    docker start --attach "$CURRENT_CONTAINER_ID" > "$CURRENT_LOG" 2>&1 || run_status=$?
    printf '%s\n' "$run_status" > "$status_temp"
    mv -f -- "$status_temp" "$status_file"
  ) &
  RUNNER_PID=$!

  deadline=$((SECONDS + 5))
  wait_for_file "$case_dir/ready" "$deadline" || fail "$case_name did not publish readiness within five seconds."
  {
    docker inspect --format 'IMAGE={{.Image}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'INIT={{.HostConfig.Init}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'AUTO_REMOVE={{.HostConfig.AutoRemove}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'NETWORK={{.HostConfig.NetworkMode}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'PRIVILEGED={{.HostConfig.Privileged}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'PID_MODE={{.HostConfig.PidMode}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format 'USERNS_MODE={{.HostConfig.UsernsMode}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format '{{range .HostConfig.CapDrop}}{{printf "CAP_DROP=%s\n" .}}{{end}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format '{{range .HostConfig.CapAdd}}{{printf "CAP_ADD=%s\n" .}}{{end}}' "$CURRENT_CONTAINER_ID"
    docker inspect --format '{{range .HostConfig.SecurityOpt}}{{printf "SECURITY_OPT=%s\n" .}}{{end}}' "$CURRENT_CONTAINER_ID"
  } > "$inspect_file" || fail "$case_name Docker inspection failed."

  grep -Fqx -- "IMAGE=$image_id" "$inspect_file" || fail "$case_name did not use the verified image."
  grep -Fqx -- 'INIT=true' "$inspect_file" || fail "$case_name did not use Docker init."
  grep -Fqx -- 'AUTO_REMOVE=true' "$inspect_file" || fail "$case_name did not enable auto-removal."
  grep -Fqx -- 'NETWORK=none' "$inspect_file" || fail "$case_name unexpectedly has a network."
  grep -Fqx -- 'PRIVILEGED=false' "$inspect_file" || fail "$case_name unexpectedly uses privileged mode."
  grep -Fqx -- 'PID_MODE=' "$inspect_file" || fail "$case_name unexpectedly uses a PID namespace mode."
  grep -Fqx -- 'USERNS_MODE=' "$inspect_file" || fail "$case_name unexpectedly uses a user namespace mode."
  assert_prefix_count 1 CAP_DROP= "$inspect_file"
  assert_prefix_count 5 CAP_ADD= "$inspect_file"
  assert_prefix_count 1 SECURITY_OPT= "$inspect_file"
  assert_line_count 1 CAP_DROP=ALL "$inspect_file"
  assert_line_count 1 CAP_ADD=CAP_CHOWN "$inspect_file"
  assert_line_count 1 CAP_ADD=CAP_DAC_OVERRIDE "$inspect_file"
  assert_line_count 1 CAP_ADD=CAP_KILL "$inspect_file"
  assert_line_count 1 CAP_ADD=CAP_SETUID "$inspect_file"
  assert_line_count 1 CAP_ADD=CAP_SETGID "$inspect_file"
  assert_line_count 1 SECURITY_OPT=no-new-privileges "$inspect_file"

  grep -Fqx -- 'READY=1' "$case_dir/ready" || fail "$case_name readiness marker is invalid."
  grep -Fqx -- "UID=$(id -u)" "$case_dir/ready" || fail "$case_name session UID is not mapped."
  grep -Fqx -- "GID=$(id -g)" "$case_dir/ready" || fail "$case_name session GID is not mapped."
  grep -Fqx -- 'PPID=1' "$case_dir/ready" || fail "$case_name session is not a direct child of PID 1."
  grep -Fqx -- 'PID1=1' "$case_dir/ready" || fail "$case_name PID 1 marker is missing."
  grep -Eq '^PID1_COMM=(docker-init|tini)$' "$case_dir/ready" || fail "$case_name PID 1 command is not docker-init/tini."
  if grep -Fqx -- 'PID1_EXE_STATUS=0' "$case_dir/ready"; then
    grep -Eq '^PID1_EXE=.*/(docker-init|tini)$' "$case_dir/ready" || fail "$case_name fixture read the wrong PID 1 executable."
  else
    grep -Fqx -- 'PID1_EXE_STATUS=1' "$case_dir/ready" || fail "$case_name fixture did not record its PID 1 readlink result."
  fi
  live_pid1_exe="$(docker exec --user 0 "$CURRENT_CONTAINER_ID" readlink /proc/1/exe)" || fail "$case_name could not inspect the PID 1 executable."
  [[ "$live_pid1_exe" =~ /(docker-init|tini)$ ]] || fail "$case_name PID 1 executable is not docker-init/tini."
  printf 'LIVE_PID1_EXE=%s\n' "$live_pid1_exe" >> "$inspect_file"
  grep -Fqx -- 'NO_NEW_PRIVS=1' "$case_dir/ready" || fail "$case_name no-new-privileges is not active."
  for field in CAP_INH CAP_PRM CAP_EFF CAP_AMB; do
    grep -Eq "^${field}=0+$" "$case_dir/ready" || fail "$case_name session $field is not zero."
  done

  signal_started=$SECONDS
  case "$case_name" in
    sigint) docker kill --signal SIGINT "$CURRENT_CONTAINER_ID" > "$command_file" 2>&1 || fail 'docker kill --signal SIGINT failed.' ;;
    sigterm) docker stop --timeout 5 "$CURRENT_CONTAINER_ID" > "$command_file" 2>&1 || fail 'docker stop --timeout 5 failed.' ;;
    *) fail "Unknown signal case: $case_name" ;;
  esac
  deadline=$((signal_started + 5))
  wait_for_file "$case_dir/signal" "$deadline" || fail "$case_name did not record the signal within five seconds."
  wait_for_file "$status_file" "$deadline" || fail "$case_name Docker run did not return within five seconds."
  wait_for_removal "$CURRENT_CONTAINER_ID" "$deadline" || fail "$case_name container was not auto-removed within five seconds."
  elapsed=$((SECONDS - signal_started))
  (( elapsed <= 5 )) || fail "$case_name exceeded the five-second completion bound."

  IFS= read -r docker_status < "$status_file"
  [[ "$docker_status" == "$expected_status" ]] || fail "$case_name Docker status was $docker_status, expected $expected_status."
  grep -Fqx -- "SIGNAL=$expected_signal" "$case_dir/signal" || fail "$case_name recorded the wrong signal."
  grep -Fqx -- "STATUS=$expected_status" "$case_dir/signal" || fail "$case_name fixture recorded the wrong status."
  if grep -Eqi 'Operation not permitted|Unexpected error when forwarding signal|SIGKILL|(^|[^[:alpha:]])Killed([^[:alpha:]]|$)|tini.*fatal|fatal.*tini' "$CURRENT_LOG"; then
    fail "$case_name output contains a signal-forwarding or forced-kill error."
  fi

  wait "$RUNNER_PID" || fail "$case_name Docker wrapper failed."
  RUNNER_PID=''
  printf 'CASE=%s\nCONTAINER=%s\nCONTAINER_ID=%s\nOWNER=%s\nELAPSED_SECONDS=%s\nDOCKER_STATUS=%s\n' "$case_name" "$CURRENT_CONTAINER" "$CURRENT_CONTAINER_ID" "$CURRENT_OWNER" "$elapsed" "$docker_status"
  sed -n '1,240p' "$case_dir/ready"
  sed -n '1,240p' "$case_dir/signal"
  sed -n '1,240p' "$inspect_file"
  sed -n '1,240p' "$CURRENT_LOG"
  printf 'REMOVED=1\nCASE_RESULT=PASS\n'
  CURRENT_CONTAINER_ID=''
  CURRENT_CONTAINER=''
  CURRENT_OWNER=''
  CURRENT_LOG=''
}

test_name_collision_safety
run_case sigint SIGINT 130
run_case sigterm SIGTERM 143
printf 'All real-Docker signal tests passed.\n'
