import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { sandbox, executable } from './helpers/fixtures.mjs';
import { pty } from './helpers/pty.mjs';

const draw = /Space: toggle|Space.*toggle/i;
async function enter(t, name, extra = {}) {
  const f = sandbox(t, name);
  f.env.FORBIDDEN_LOG = path.join(f.dir, 'forbidden.log');
  executable(path.join(f.bin, 'docker'), 'printf docker >> \"$FORBIDDEN_LOG\"; exit 91');
  executable(path.join(f.bin, 'curl'), 'printf curl >> \"$FORBIDDEN_LOG\"; exit 92');
  const p = pty(t, f, extra);
  await p.waitFor(/Up\/Down: navigate/);
  await p.send('5', draw);
  const finish = p.finish;
  p.finish = async (...args) => { const output = await finish(...args); assert.equal(fs.existsSync(f.env.FORBIDDEN_LOG), false, 'Tools selection must not build or use network'); return output; };
  return { f, p };
}

test('AC2 Tools PTY wraps, skips headings and Space/Enter commits with restored terminal', async t => {
  const { f, p } = await enter(t, 'tools-pty-save');
  await p.send('\x1b[A', draw);
  await p.send('\x1b[B', draw);
  const beforeToggle = p.offset;
  await p.send(' ', draw);
  const toggleFrame = p.output.slice(beforeToggle);
  assert.equal(toggleFrame.includes('\x1b[?1049l'), false, 'Space must not leave the Tools screen');
  assert.equal(toggleFrame.includes('\x1b[?1049h'), false, 'Space must not re-enter the Tools screen');
  assert.equal(toggleFrame.includes('\x1b[?25h'), false, 'Space must keep the cursor hidden');
  await p.send('\n', /CodexShell v/);
  assert.match(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), /^TOOL_DOCKER_CLI=on$/m);
  await p.send('q');
  await p.finish();
});

for (const [name, key] of [['q', 'q'], ['Escape', '\x1b'], ['EOF', '\x04']]) {
  test(`AC2 Tools PTY ${name} discards staged values and restores terminal`, async t => {
    const { f, p } = await enter(t, `tools-pty-${name}`);
    await p.send(' ', draw);
    await p.send(key, /CodexShell v/);
    assert.equal(fs.existsSync(path.join(f.app, 'config/tools.conf')), false);
    await p.send('q'); await p.finish();
  });
}
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
  test(`AC2 Tools PTY ${signal} discards settings and restores exact terminal`, async t => {
    const { f, p } = await enter(t, `tools-pty-${signal}`);
    await p.send(' ', draw);
    p.signal(signal);
    await p.finish(code);
    assert.equal(fs.existsSync(path.join(f.app, 'config/tools.conf')), false);
  });
}

test('AC2 short Tools viewport keeps focused row and footer visible', async t => {
  const f = sandbox(t, 'tools-pty-short');
  executable(path.join(f.bin, 'tput'), `case "$1" in lines) printf '8\\n' ;; cols) printf '60\\n' ;; *) exec /usr/bin/tput "$@" ;; esac`);
  const p = pty(t, f);
  await p.waitFor(/Up\/Down: navigate/); await p.send('5', draw);
  for (let i = 0; i < 22; i++) await p.send('\x1b[B', draw);
  const lastFrame = p.output.slice(p.output.lastIndexOf('Tools\r\n'));
  assert.ok(lastFrame.split('\n').length <= 10, JSON.stringify(lastFrame));
  assert.match(lastFrame, /wget|Back/i);
  assert.match(lastFrame, draw);
  await p.send('q', /CodexShell v/); await p.send('q'); await p.finish();
});

test('AC2 Tools arrows skip group headings and explicit Back commits staged selection', async t => {
  const { f, p } = await enter(t, 'tools-pty-groups');
  for (let i = 0; i < 10; i++) await p.send('\x1b[B', draw);
  await p.send(' ', draw);
  for (let i = 0; i < 12; i++) await p.send('\x1b[B', draw);
  await p.send('\n', /CodexShell v/);
  assert.match(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), /^TOOL_GH_CLI=on$/m);
  await p.send('q'); await p.finish();
});
