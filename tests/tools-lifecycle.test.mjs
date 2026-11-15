import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { sandbox, executable, bash } from './helpers/fixtures.mjs';

function lifecycle(t) {
  const f = sandbox(t, 'tools-lifecycle');
  const tools = path.join(f.dir, 'xcode-tools'); fs.mkdirSync(tools);
  for (const name of ['xcodebuild', 'xcrun']) executable(path.join(tools, name), 'exit 0');
  const lib = path.join(f.app, 'scripts/platform/macos/lib-xcode-bridge.sh');
  fs.writeFileSync(lib, fs.readFileSync(lib, 'utf8').replaceAll('/usr/bin/xcodebuild', path.join(tools, 'xcodebuild')).replaceAll('/usr/bin/xcrun', path.join(tools, 'xcrun')));
  executable(path.join(f.bin, 'uname'), "printf 'Darwin\\n'");
  executable(path.join(f.bin, 'xcode-select'), 'exit "${NO_XCODE:-0}"');
  const python = spawnSync('bash', ['-c', 'command -v python3'], { env: process.env, encoding: 'utf8' });
  assert.equal(python.status, 0, 'python3 must be available on the original PATH');
  f.env.QA_REAL_PYTHON = python.stdout.trim();
  executable(path.join(f.bin, 'python3'), `session=''; server=0; args=("$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[$i]}" == --session ]]; then session=\${args[$((i+1))]}; fi
  if [[ "\${args[$i]}" == --project-root ]]; then server=1; fi
done
if [[ "$server" == 1 ]]; then
  if [[ -n "\${QA_START_MARKER:-}" ]]; then printf '%s\\n%s\\n' "$$" "$session" > "$QA_START_MARKER"; fi
  sleep "\${QA_START_DELAY:-0}"
  [[ "\${QA_FAIL_START:-0}" == 0 ]] || exit 77
fi
exec "$QA_REAL_PYTHON" "$@" --tool-root "$FAKE_TOOL_ROOT" --bind 127.0.0.1`);
  f.env.FAKE_TOOL_ROOT = tools;
  return f;
}

test('AC8 real adapter authenticates/reuses current owned bridge and replaces changed mount map', t => {
  const f = lifecycle(t);
  const r = bash(f, `source "$1/scripts/platform/macos/lib-xcode-bridge.sh"
trap xcode_bridge_cleanup EXIT
xcode_bridge_start "$1" "$1" /workspace/first
first=$_XCODE_CHILD
session=$_XCODE_SESSION
[[ "$XCODE_BRIDGE_ACTIVE" == 1 && -f "$session/token" ]]
xcode_bridge_start "$1" "$1" /workspace/first
[[ "$_XCODE_CHILD" == "$first" ]]
if xcode_bridge_start "$1" /missing /workspace/invalid; then exit 91; fi
[[ "$_XCODE_CHILD" == "$first" && "$XCODE_BRIDGE_ACTIVE" == 1 ]]
xcode_bridge_start "$1" "$1" /workspace/second
[[ "$_XCODE_CHILD" != "$first" ]]
[[ ! -e "$session" ]]
xcode_bridge_stop
[[ "$XCODE_BRIDGE_ACTIVE" == 0 ]]
xcode_bridge_cleanup
printf 'LIFECYCLE=ok\\n'`);
  assert.equal(r.status, 0, r.stderr + r.stdout); assert.match(r.stdout, /LIFECYCLE=ok/);
});

test('AC8 missing prerequisites and stale metadata never signal an unrelated live process', t => {
  const f = lifecycle(t);
  const r = bash(f, `source "$1/scripts/platform/macos/lib-xcode-bridge.sh"
if NO_XCODE=1 xcode_bridge_start "$1"; then exit 91; fi
sleep 30 & unrelated=$!
trap 'kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true' EXIT
_XCODE_CHILD=999999
_XCODE_SESSION=''
xcode_bridge_stop
kill -0 "$unrelated"
printf 'UNRELATED=alive\\n'`);
  assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, /UNRELATED=alive/);
});

for (const [before, action, expected] of [['0', 'cancel', 'STOP=1'], ['1', 'cancel', 'STOP=0'], ['1', 'commit', 'STOP=1'], ['0', 'failed-save', 'STOP=1']]) {
  test(`AC8 Tools ${action} restores adapter entry activity ${before}`, t => {
    const f = sandbox(t, 'tools-transaction'); executable(path.join(f.bin, 'uname'), "printf 'Darwin\\n'");
    fs.mkdirSync(path.join(f.app, 'config'));
    fs.writeFileSync(path.join(f.app, 'config/tools.conf'), `TOOL_XCODE=${before === '1' ? 'on' : 'off'}\n`);
    const original = fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8');
    const r = bash(f, `source "$1/scripts/lib-tools.sh"
menu_cleanup() { :; }
XCODE_BRIDGE_ACTIVE=${before}; stops=0
xcode_bridge_stop() { stops=$((stops+1)); XCODE_BRIDGE_ACTIVE=0; }
menu_tools() { ${before === '1' ? 'tools_set XCODE off' : 'tools_set XCODE on; XCODE_BRIDGE_ACTIVE=1'}; return ${action === 'cancel' ? '3' : '0'}; }
${action === 'failed-save' ? 'tools_save() { return 1; }' : ''}
if tools_manage "$1"; then :; fi
printf 'STOP=%s\\n' "$stops"`);
    assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, new RegExp(expected));
    if (action !== 'commit') assert.equal(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), original);
  });
}

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
  test(`AC8 delayed bridge startup ${signal} cleans unpublished session and child`, async t => {
    const f = lifecycle(t);
    f.env.QA_START_DELAY = '1';
    f.env.QA_START_MARKER = path.join(f.dir, 'starting');
    const launcher = spawn('bash', ['-c', `source "$1/scripts/platform/macos/lib-xcode-bridge.sh"
trap xcode_bridge_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
xcode_bridge_start "$1"
printf 'UNEXPECTED_READY\\n'`, 'codexshell-delayed-test', f.app], { env: f.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    launcher.stdout.on('data', data => output += data); launcher.stderr.on('data', data => output += data);
    const closed = new Promise(resolve => launcher.once('close', status => resolve(status)));
    const watchdog = setTimeout(() => launcher.kill('SIGKILL'), 10000);
    let bridgePid, session;
    try {
      const deadline = Date.now() + 3000;
      while (!fs.existsSync(f.env.QA_START_MARKER) && Date.now() < deadline && launcher.exitCode === null) await new Promise(resolve => setTimeout(resolve, 10));
      assert.equal(fs.existsSync(f.env.QA_START_MARKER), true, output);
      [bridgePid, session] = fs.readFileSync(f.env.QA_START_MARKER, 'utf8').trim().split('\n');
      assert.equal(fs.existsSync(path.join(session, 'manifest.json')), false, 'signal must precede ready publication');
      launcher.kill(signal);
      assert.equal(await closed, code, output);
      await new Promise(resolve => setTimeout(resolve, 1200));
      assert.equal(fs.existsSync(session), false, 'pending private session must be removed');
      assert.throws(() => process.kill(Number(bridgePid), 0), /ESRCH/, 'pending bridge must be reaped');
      assert.doesNotMatch(output, /UNEXPECTED_READY/);
    } finally {
      clearTimeout(watchdog);
      if (launcher.exitCode === null) launcher.kill('SIGKILL');
      if (bridgePid) { try { process.kill(Number(bridgePid), 'SIGKILL'); } catch {} }
      if (session) fs.rmSync(session, { recursive: true, force: true });
      await closed;
    }
  });
}

test('AC8 failed replacement startup preserves the active bridge and cleans pending session', t => {
  const f = lifecycle(t);
  f.env.QA_START_MARKER = path.join(f.dir, 'replacement');
  const r = bash(f, `source "$1/scripts/platform/macos/lib-xcode-bridge.sh"
trap xcode_bridge_cleanup EXIT
xcode_bridge_start "$1"
first=$_XCODE_CHILD; session=$_XCODE_SESSION
if QA_FAIL_START=1 xcode_bridge_start "$1" "$1" /workspace/replacement; then exit 91; fi
[[ "$_XCODE_CHILD" == "$first" && "$_XCODE_SESSION" == "$session" && "$XCODE_BRIDGE_ACTIVE" == 1 ]]
"$_XCODE_PYTHON" "$_XCODE_HELPER" --session "$session" --control health
IFS= read -r failed_pid < "$QA_START_MARKER"
failed_session=$(sed -n '2p' "$QA_START_MARKER")
[[ ! -e "$failed_session" ]]
if kill -0 "$failed_pid" 2>/dev/null; then exit 92; fi
printf 'PRESERVED=ok\\n'`);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.match(r.stdout, /PRESERVED=ok/);
});
