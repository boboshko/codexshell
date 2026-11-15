import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';

export function pty(t, fixture, extra = {}) {
  const before = path.join(fixture.dir, 'tty-before');
  const after = path.join(fixture.dir, 'tty-after');
  const pidFile = path.join(fixture.dir, 'tty-app-pid');
  const statusFile = path.join(fixture.dir, 'tty-status');
  const wrapper = path.join(fixture.dir, 'pty-wrapper.sh');
  fs.writeFileSync(wrapper, `#!/usr/bin/env bash\nstty -g > "$PTY_BEFORE"\nbash -c 'printf "%s\\n" "$$" > "$PTY_PID"; exec bash "$PTY_APP/start.sh"'\nstatus=$?\nstty -g > "$PTY_AFTER"\nprintf '%s\\n' "$status" > "$PTY_STATUS"\nexit "$status"\n`);
  const scriptArgs = process.platform === 'darwin'
    ? ['-q', '/dev/null', 'bash', '-c', 'bash "$PTY_WRAPPER"']
    : ['-qefc', 'bash "$PTY_WRAPPER"', '/dev/null'];
  const child = spawn('script', scriptArgs, {
    cwd: fixture.app,
    env: { ...fixture.env, TERM: 'xterm', PTY_WRAPPER: wrapper, PTY_APP: fixture.app, PTY_BEFORE: before, PTY_AFTER: after, PTY_PID: pidFile, PTY_STATUS: statusFile, ...extra },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let output = '';
  let finished = false;
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  const completion = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', (code, signal) => { finished = true; resolve({ code, signal }); });
  });
  const watchdog = setTimeout(() => child.kill('SIGKILL'), 12000);
  t.after(() => { clearTimeout(watchdog); child.stdin.destroy(); if (!finished) child.kill('SIGKILL'); });
  async function waitFor(pattern, offset = 0, timeout = 4000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (pattern.test(output.slice(offset))) return output.length;
      if (finished) break;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.fail(`PTY did not produce ${pattern}; output since ${offset}: ${JSON.stringify(output.slice(offset))}`);
  }
  return {
    before,
    get output() { return output; },
    get offset() { return output.length; },
    waitFor,
    async send(keys, pattern) {
      const offset = output.length;
      child.stdin.write(keys);
      if (pattern) await waitFor(pattern, offset);
    },
    signal(name) { process.kill(Number(fs.readFileSync(pidFile, 'utf8').trim()), name); },
    async finish(expected = 0, cursor = true) {
      const result = await completion;
      clearTimeout(watchdog);
      if (process.platform === 'darwin') assert.ok(result.code === 0 || result.code === expected, output);
      else assert.equal(result.code, expected, output);
      assert.equal(fs.readFileSync(statusFile, 'utf8').trim(), String(expected));
      assert.equal(fs.readFileSync(after, 'utf8'), fs.readFileSync(before, 'utf8'), 'exact stty state must be restored');
      if (cursor) {
        const hidden = output.lastIndexOf('\x1b[?25l');
        const visible = output.lastIndexOf('\x1b[?25h');
        assert.ok(hidden >= 0 && visible > hidden, 'cursor must be shown after its final hide');
      }
      return output;
    },
  };
}
