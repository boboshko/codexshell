import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { sandbox, executable, bash, start } from './helpers/fixtures.mjs';

const slugs = ['DOCKER_CLI','DOCKER_COMPOSE','DOCKER_SOCKET','PYTHON','GO','RUST','JAVA','MAKE','CMAKE','BUILD_ESSENTIAL','GH_CLI','POSTGRES','MONGODB','REDIS','PNPM','BUN','UV','SSH_CLIENT','RSYNC','JQ','YQ','WGET','XCODE'];
const load = 'source "$1/scripts/lib-tools.sh"; tools_load "$1"';
function config(f, data) {
  fs.mkdirSync(path.join(f.app, 'config'), { recursive: true });
  fs.writeFileSync(path.join(f.app, 'config/tools.conf'), data);
}
function docker(f) {
  f.env.DOCKER_LOG = path.join(f.dir, 'docker.log');
  f.env.DOCKER_ID = path.join(f.dir, 'image-id');
  executable(path.join(f.bin, 'docker'), `printf '%s\\n' "$*" >> "$DOCKER_LOG"
case "$1" in
 info) exit 0 ;;
 image) [[ -f "$DOCKER_ID" ]] || exit 1; cat "$DOCKER_ID" ;;
 build) [[ "\${FAIL_BUILD:-0}" == 0 ]] || exit 9; printf 'sha256:built\\n' > "$DOCKER_ID" ;;
 run) exit 0 ;;
 *) exit 98 ;;
esac`);
}
function builds(f) { return fs.existsSync(f.env.DOCKER_LOG) ? fs.readFileSync(f.env.DOCKER_LOG, 'utf8').split('\n').filter(l => l.startsWith('build ')).length : 0; }

test('AC1 catalog has exact order, 23 defaults off and 21 image-only build flags', t => {
  const f = sandbox(t, 'tools-catalog');
  const rows = fs.readFileSync(path.join(f.app, 'scripts/tools-catalog.tsv'), 'utf8').trimEnd().split('\n').map(line => line.split('\t'));
  assert.deepEqual(rows.map(r => r[2]), ['Docker CLI','Docker Compose','Docker socket access','Python','Go','Rust','Java','Make','CMake','GCC/Clang','GitHub CLI','PostgreSQL','MongoDB','Redis','pnpm','Bun','uv','SSH client','rsync','jq','yq','wget','Xcode']);
  assert.deepEqual(rows.map(r => r[1]), [...Array(10).fill('Development'), 'Version Control', ...Array(3).fill('Databases'), ...Array(3).fill('Package Managers'), ...Array(5).fill('Utilities'), 'macOS only']);
  assert.equal(rows.at(-1)[4], 'macos');
  const r = bash(f, `${load}; printf '%s\\n' "\${TOOLS_SLUGS[@]}"; printf 'VALUE:%s\\n' "\${TOOLS_VALUES[@]}"; tools_build_args; printf 'ARG:%s\\n' "\${TOOLS_BUILD_ARGS[@]}"`);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.stdout.split('\n').filter(l => l && !l.startsWith('VALUE:') && !l.startsWith('ARG:')), slugs);
  assert.equal(r.stdout.match(/VALUE:off/g)?.length, 23);
  const args = r.stdout.split('\n').filter(l => l.startsWith('ARG:TOOL_'));
  assert.equal(args.length, 21);
  assert.ok(args.every(l => l.endsWith('=0')));
  assert.ok(!args.some(l => /SOCKET|XCODE/.test(l)));
  assert.equal(fs.existsSync(path.join(f.app, 'config')), false);
  const menu = start(f, '0\n').stdout;
  assert.ok(menu.indexOf('Firewall') < menu.indexOf('Tools'));
  assert.doesNotMatch(start(f, '5\ncancel\n0\n').stdout, /Xcode/);
  executable(path.join(f.bin, 'uname'), "printf 'Darwin\\n'");
  assert.match(start(f, '5\ncancel\n0\n').stdout, /Xcode/);
});

test('AC3 missing values default off, uv selects Python and prevents Python removal', t => {
  const f = sandbox(t, 'tools-dependency');
  config(f, 'TOOL_GO=on\n');
  const r = bash(f, `${load}; tools_get GO; tools_get PYTHON; tools_set UV on; tools_get PYTHON; if tools_set PYTHON off; then exit 88; fi; tools_save "$1"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /on\noff\n/);
  const data = fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8');
  assert.match(data, /^TOOL_PYTHON=on$/m);
  assert.match(data, /^TOOL_UV=on$/m);
  assert.equal(fs.statSync(path.join(f.app, 'config/tools.conf')).mode & 0o777, 0o600);
  assert.equal(fs.readdirSync(path.join(f.app, 'config')).filter(x => x !== 'tools.conf').length, 0);
});

test('AC3 malformed, unknown, duplicate, shell-shaped, unsupported and oversized settings fail closed', t => {
  const cases = ['TOOL_GO=yes\n', 'TOOL_UNKNOWN=on\n', 'TOOL_GO=on\nTOOL_GO=off\n', 'TOOL_GO=$(touch injected)\n', 'TOOL_GO=on;touch injected\n', 'TOOL_XCODE=on\n', 'TOOL_UV=on\n', 'TOOL_GO=on\r\n', 'x'.repeat(1024*1024)];
  for (const data of cases) {
    const f = sandbox(t, 'tools-invalid'); config(f, data);
    const r = bash(f, load);
    assert.notEqual(r.status, 0, data.slice(0, 80));
    assert.equal(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), data);
    assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
  }
});

test('AC3 atomic save rejects links and write failure without replacing committed data', t => {
  for (const mode of ['destination', 'directory', 'rename']) {
    const f = sandbox(t, 'tools-save'); config(f, 'TOOL_GO=off\n');
    const target = path.join(f.app, 'config/tools.conf');
    if (mode === 'destination') { fs.renameSync(target, path.join(f.dir, 'outside')); fs.symlinkSync(path.join(f.dir, 'outside'), target); }
    if (mode === 'directory') { fs.renameSync(path.join(f.app, 'config'), path.join(f.dir, 'outside-config')); fs.symlinkSync(path.join(f.dir, 'outside-config'), path.join(f.app, 'config')); }
    const r = bash(f, `source "$1/scripts/lib-tools.sh"; ${mode === 'rename' ? 'tools_load "$1"; tools_set GO on; mv() { return 73; }; tools_save "$1"' : 'tools_load "$1"'}`);
    assert.notEqual(r.status, 0, mode);
    assert.equal(fs.readFileSync(target, 'utf8'), 'TOOL_GO=off\n');
    if (mode === 'rename') assert.deepEqual(fs.readdirSync(path.dirname(target)), ['tools.conf']);
  }
});

test('AC6 trusted catalog extension reaches settings, menu and build arguments', t => {
  const f = sandbox(t, 'tools-extension');
  fs.appendFileSync(path.join(f.app, 'scripts/tools-catalog.tsv'), 'FIXTURE\tFixture group\tFixture tool\timage\tall\t-\n');
  const r = bash(f, `${load}; tools_set FIXTURE on; tools_save "$1"; tools_build_args; printf '%s\\n' "\${TOOLS_BUILD_ARGS[@]}"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /TOOL_FIXTURE=1/);
  assert.match(start(f, '5\ncancel\n0\n').stdout, /Fixture tool/);
});

test('AC2 plain multi-digit toggle saves; cancel, EOF and invalid input preserve settings without ANSI', t => {
  const f = sandbox(t, 'tools-plain'); docker(f);
  const r = start(f, '5\n21\nsave\n0\n');
  assert.equal(r.status, 0, r.stderr);
  assert.match(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), /^TOOL_YQ=on$/m);
  const before = fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8');
  for (const tail of ['1\ncancel\n0\n', '1\nq\n0\n', '1\n', '999\ncancel\n0\n']) {
    const c = start(f, '5\n' + tail);
    assert.equal(c.status, 0, c.stderr);
    assert.equal(c.stdout.includes('\x1b'), false);
    assert.equal(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), before);
    assert.ok(c.stdout.length < 100000);
  }
  assert.equal(fs.existsSync(f.env.DOCKER_LOG), false);
});

test('AC5 image cache is bound to inputs and image ID and excludes runtime state', t => {
  const f = sandbox(t, 'build-cache'); docker(f);
  const run = () => bash(f, 'source "$1/scripts/lib-tools.sh"; source "$1/scripts/lib-build.sh"; tools_load "$1"; build_ensure "$1" v0.1.0');
  let r = run(); assert.equal(r.status, 0, r.stderr); assert.equal(builds(f), 1);
  r = run(); assert.equal(r.status, 0, r.stderr); assert.equal(builds(f), 1);
  config(f, 'TOOL_DOCKER_SOCKET=on\n'); assert.equal(run().status, 0); assert.equal(builds(f), 1);
  executable(path.join(f.bin, 'uname'), "printf 'Darwin\\n'");
  config(f, 'TOOL_DOCKER_SOCKET=on\nTOOL_XCODE=on\n'); assert.equal(run().status, 0); assert.equal(builds(f), 1);
  config(f, 'TOOL_GO=on\n'); assert.equal(run().status, 0); assert.equal(builds(f), 2);
  fs.writeFileSync(f.env.DOCKER_ID, 'sha256:replaced\n'); assert.equal(run().status, 0); assert.equal(builds(f), 3);
  fs.appendFileSync(path.join(f.app, 'docker/install-tools.sh'), '\n:\n'); assert.equal(run().status, 0); assert.equal(builds(f), 4);
  fs.appendFileSync(path.join(f.app, 'docker/xcode-shims/xcodebuild'), '\n:\n'); assert.equal(run().status, 0); assert.equal(builds(f), 5);
  const versionRun = bash(f, 'source "$1/scripts/lib-tools.sh"; source "$1/scripts/lib-build.sh"; build_ensure "$1" v0.2.0');
  assert.equal(versionRun.status, 0, versionRun.stderr); assert.equal(builds(f), 6);
  const record = fs.readFileSync(path.join(f.app, 'config/build-fingerprint'), 'utf8');
  config(f, 'TOOL_JQ=on\n'); f.env.FAIL_BUILD = '1';
  assert.notEqual(run().status, 0);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/build-fingerprint'), 'utf8'), record);
  assert.ok(!fs.readFileSync(f.env.DOCKER_LOG, 'utf8').split('\n').some(l => l.startsWith('run ')));
});

test('AC3 interrupted atomic settings save preserves committed data and cleans private temporary files', t => {
  const f = sandbox(t, 'tools-save-term'); config(f, 'TOOL_GO=off\n');
  executable(path.join(f.bin, 'mv'), 'kill -TERM "$PPID"; exit 73');
  const r = start(f, '5\n1\nsave\n');
  assert.equal(r.status, 143, r.stderr);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), 'TOOL_GO=off\n');
  assert.equal(fs.readdirSync(path.join(f.app, 'config')).some(name => name.startsWith('.tools.')), false);
  assert.equal(fs.existsSync(path.join(f.app, '.codexshell-update.lock')), false);
});

test('AC3 strict-mode first catalog load and missing/empty catalogs fail predictably', t => {
  for (const state of ['valid', 'missing', 'empty']) {
    const f = sandbox(t, 'tools-catalog-strict');
    const catalog = path.join(f.app, 'scripts/tools-catalog.tsv');
    if (state === 'missing') fs.unlinkSync(catalog);
    if (state === 'empty') fs.writeFileSync(catalog, '');
    const r = bash(f, 'set -euo pipefail; source "$1/scripts/lib-tools.sh"; tools_load "$1"');
    assert.equal(r.status, state === 'valid' ? 0 : 2, r.stderr);
    assert.equal(fs.existsSync(path.join(f.app, 'config')), false);
  }
});
