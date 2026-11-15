import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { sandbox, executable, start, bash } from './helpers/fixtures.mjs';

function docker(f) {
  const log = path.join(f.dir, 'docker.log');
  executable(path.join(f.bin, 'docker'), `printf '%s\\n' "$@" >> "$DOCKER_LOG"\ncase "$1" in\n image) printf 'sha256:fixture\\n' ;;\n info) exit "\${DOCKER_INFO_STATUS:-0}" ;;\n build) exit "\${DOCKER_BUILD_STATUS:-0}" ;;\n run) exit "\${DOCKER_RUN_STATUS:-0}" ;;\n *) exit 99 ;;\nesac`);
  f.env.DOCKER_LOG = log;
  return log;
}

test('--version uses VERSION without network, Docker, or configuration writes', t => {
  const f = sandbox(t, 'version-cli');
  const log = path.join(f.dir, 'forbidden.log');
  for (const name of ['curl', 'docker']) executable(path.join(f.bin, name), `printf '%s\\n' invoked >> "$FORBIDDEN_LOG"; exit 91`);
  f.env.FORBIDDEN_LOG = log;
  const version = fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8').trim();
  const result = start(f, '', ['--version'], { CODEXSHELL_NO_UPDATE_CHECK: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.stdout.includes(version));
  assert.equal(fs.existsSync(path.join(f.app, 'config')), false);
  assert.equal(fs.existsSync(log), false);
  fs.writeFileSync(path.join(f.app, 'VERSION'), 'v9.8.7\n');
  assert.match(start(f, '', ['--version']).stdout, /v9\.8\.7/);
  assert.match(start(f, '0\n').stdout, /v9\.8\.7/);
});

test('plain menu handles invalid input and EOF without terminal escape output', t => {
  const f = sandbox(t, 'plain-menu');
  for (const term of ['dumb', '', 'xterm']) {
    const result = start(f, 'invalid\n\n0\n', [], { TERM: term });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Launch Codex/);
    assert.match(result.stdout, /Manage folders/);
    assert.equal(result.stdout.includes('\x1b'), false);
  }
  for (const input of ['', '2\n', '3\n', '2\n1\n', '2\n2\n']) {
    const result = start(f, input);
    assert.equal(result.status, 0, `${JSON.stringify(input)}: ${result.stderr}`);
    assert.equal(result.error, undefined);
    assert.ok(result.stdout.length < 100000, 'EOF must not cause a redraw loop');
  }
});

test('folder add/remove accepts spaces and literal shell-shaped names', t => {
  const f = sandbox(t, 'folders');
  const project = path.join(f.dir, 'project Ω $(touch injected)');
  fs.mkdirSync(project);
  const added = start(f, `2\n1\n${project}\n0\n0\n`);
  assert.equal(added.status, 0, added.stderr);
  const file = path.join(f.app, 'config/folders.txt');
  assert.equal(fs.readFileSync(file, 'utf8'), project + '\n');
  assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
  const duplicate = start(f, `2\n1\n${project}\n\n0\n0\n`);
  assert.equal(duplicate.status, 0, duplicate.stderr);
  assert.match(duplicate.stdout, /Already mounted/);
  assert.equal(fs.readFileSync(file, 'utf8'), project + '\n');
  const removed = start(f, '2\n2\n1\n0\n0\n');
  assert.equal(removed.status, 0, removed.stderr);
  assert.equal(fs.readFileSync(file, 'utf8'), '');
});

test('invalid folder and root paths are rejected without changing registered folders', t => {
  const f = sandbox(t, 'folder-invalid');
  for (const folder of ['/', path.join(f.dir, 'missing')]) {
    const result = start(f, `2\n1\n${folder}\n\n0\n0\n`);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(f.app, 'config/folders.txt'), 'utf8'), '');
  }
});

test('firewall actions persist mode and expose the existing allowlist', t => {
  const f = sandbox(t, 'firewall');
  assert.equal(start(f, '3\n2\n0\n0\n').status, 0);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/firewall'), 'utf8'), 'disabled\n');
  assert.equal(start(f, '3\n1\n0\n0\n').status, 0);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/firewall'), 'utf8'), 'enabled\n');
  const viewed = start(f, '3\n3\n\n0\n0\n');
  assert.equal(viewed.status, 0, viewed.stderr);
  assert.ok(viewed.stdout.includes(fs.readFileSync(path.join(f.app, 'docker/allowed-domains.txt'), 'utf8').trim()));
});

test('Docker errors return to the menu without running a failed image', t => {
  const f = sandbox(t, 'docker-errors');
  const log = docker(f);
  for (const extra of [{ DOCKER_INFO_STATUS: '1' }, { DOCKER_BUILD_STATUS: '1' }]) {
    fs.writeFileSync(log, '');
    const result = start(f, '1\n\n0\n', [], extra);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(log, 'utf8').split('\n').includes('run'), false);
  }
  fs.writeFileSync(log, '');
  const failedRun = start(f, '1\n\n0\n', [], { DOCKER_RUN_STATUS: '7' });
  assert.equal(failedRun.status, 0, failedRun.stderr);
  assert.match(failedRun.stdout, /error|failed/i);
});

test('menu library fallback returns selected keys and handles EOF', t => {
  const f = sandbox(t, 'menu-library');
  const selected = bash(f, 'source "$1/scripts/lib-menu.sh"; if menu_select Test 1 First 2 Second 0 Back; then printf "KEY=%s\\n" "$MENU_KEY"; else printf "EOF\\n"; fi', {});
  assert.equal(selected.status, 0, selected.stderr);
  assert.match(selected.stdout, /EOF/);
});
