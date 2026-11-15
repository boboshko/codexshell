import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { sandbox, executable } from './helpers/fixtures.mjs';
import { pty } from './helpers/pty.mjs';

const draw = /Up\/Down: navigate/;
const down = '\x1b[B';
const up = '\x1b[A';
async function move(p, keys) {
  for (const key of keys) await p.send(key, draw);
}

test('real PTY routes all main/folder/firewall actions and restores TTY before prompts and Docker', async t => {
  const f = sandbox(t, 'pty-actions');
  const project = path.join(f.dir, 'project Ω $(touch injected)');
  fs.mkdirSync(project);
  const log = path.join(f.dir, 'docker.log');
  executable(path.join(f.bin, 'docker'), `if [[ "$1" == run ]]; then\n  [[ -t 0 && -t 1 ]]\n  [[ "$(stty -g)" == "$(cat "$PTY_BEFORE")" ]]\nfi\nprintf '%s\\n' "$1" >> "$DOCKER_LOG"; if [[ "$1" == image ]]; then printf 'sha256:fixture\\n'; fi`);
  f.env.DOCKER_LOG = log;
  const p = pty(t, f);
  await p.waitFor(draw);
  await move(p, [down]);
  await p.send('\n', /Mounted folders:/);
  await p.send('\n', /Absolute local folder path:/);
  assert.ok(p.output.lastIndexOf('\x1b[?25h') > p.output.lastIndexOf('\x1b[?25l'));
  await p.send(project + '\n', draw);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/folders.txt'), 'utf8'), project + '\n');
  await move(p, [down]);
  await p.send('\n', /Folder number to remove:/);
  await p.send('1\n', draw);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/folders.txt'), 'utf8'), '');
  await move(p, [up]);
  await p.send('\n', /CodexShell v/);
  await move(p, [down, down]);
  await p.send('\n', /Firewall: enabled/);
  await move(p, [down]);
  await p.send('\n', /Firewall: disabled/);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/firewall'), 'utf8'), 'disabled\n');
  await p.send('\n', /Firewall: enabled/);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/firewall'), 'utf8'), 'enabled\n');
  await move(p, [down, down]);
  await p.send('\n', /Press Enter to continue/);
  assert.ok(p.output.includes(fs.readFileSync(path.join(f.app, 'docker/allowed-domains.txt'), 'utf8').trim().replaceAll('\n', '\r\n')));
  await p.send('\n', draw);
  await move(p, [up]);
  await p.send('\n', /CodexShell v/);
  await p.send('\n', /Starting Codex/);
  await p.waitFor(draw, p.output.lastIndexOf('Starting Codex'));
  assert.ok(fs.readFileSync(log, 'utf8').includes('build\n'));
  assert.ok(fs.readFileSync(log, 'utf8').endsWith('run\n'));
  await move(p, [up]);
  await p.send('\n');
  await p.finish();
  assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
});

test('real PTY down wrapping, q back/exit and numeric shortcuts restore terminal', async t => {
  const f = sandbox(t, 'pty-wrap');
  executable(path.join(f.bin, 'docker'), 'exit 1');
  const p = pty(t, f);
  await p.waitFor(draw);
  await move(p, [down, down, down, down, down]);
  await p.send('\n', /Starting Codex|Docker is required|Docker daemon|No local folders/);
  await p.send('\n', draw);
  await p.send('2', /Mounted folders:/);
  await p.send('q', /CodexShell v/);
  await p.send('3', /Firewall:/);
  await p.send('q', /CodexShell v/);
  await p.send('q');
  await p.finish();
});

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
  test(`real PTY ${signal} restores exact attributes and cursor`, async t => {
    const f = sandbox(t, `pty-${signal}`);
    const p = pty(t, f);
    await p.waitFor(draw);
    p.signal(signal);
    await p.finish(code);
  });
}

test('real PTY EOF restores exact attributes and cursor', async t => {
  const f = sandbox(t, 'pty-eof');
  const p = pty(t, f);
  await p.waitFor(draw);
  await p.send('\x04');
  await p.finish();
});

test('real PTY lone/incomplete Escape responds within a bounded time', async t => {
  const f = sandbox(t, 'pty-escape');
  const p = pty(t, f);
  await p.waitFor(draw);
  const started = Date.now();
  await p.send('\x1b', draw);
  assert.ok(Date.now() - started < 2500);
  await p.send('\x1b[', draw);
  await p.send('q');
  await p.finish();
});

for (const mode of ['dumb', 'empty', 'missing-tput', 'failing-tput']) {
  test(`real PTY ${mode} uses plain numeric fallback without ANSI noise`, async t => {
    const f = sandbox(t, `pty-${mode}`);
    const extra = { TERM: mode === 'dumb' ? 'dumb' : mode === 'empty' ? '' : 'xterm' };
    if (mode === 'missing-tput') {
      const bashEnv = path.join(f.dir, 'bash-env');
      fs.writeFileSync(bashEnv, 'command() { if [[ "$1" == -v && "${2:-}" == tput ]]; then return 1; fi; builtin command "$@"; }\n');
      extra.BASH_ENV = bashEnv;
    }
    if (mode === 'failing-tput') executable(path.join(f.bin, 'tput'), 'exit 1');
    const p = pty(t, f, extra);
    await p.waitFor(/Select an option/);
    await p.send('invalid\n', /Invalid selection/);
    await p.send('2\n', /Mounted folders:/);
    await p.send('0\n', /CodexShell v/);
    await p.send('0\n');
    const output = await p.finish(0, false);
    assert.equal(output.includes('\x1b'), false);
  });
}
