import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { sandbox } from './helpers/fixtures.mjs';

async function bridge(t) {
  const f = sandbox(t, 'tools-bridge');
  const session = path.join(f.dir, 'session'); fs.mkdirSync(session, { mode: 0o700 });
  const tools = path.join(f.dir, 'developer-tools'); fs.mkdirSync(tools);
  const host1 = path.join(f.dir, 'one/project Ω'); const host2 = path.join(f.dir, 'two/project Ω');
  const container2 = path.join(f.dir, 'container-project-2');
  for (const dir of [host1, host2, container2]) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(host1, 'Project Ω.xcodeproj'), 'fixture');
  fs.symlinkSync(f.dir, path.join(host1, 'escape'));
  const fake = `#!${process.execPath}
const fs = require('node:fs');
const a = process.argv.slice(2);
if (a[0] === '-version') { process.stdout.write(Buffer.from([65,0,255,10])); process.stderr.write(Buffer.from([69,0,254,10])); process.exitCode = 7; }
else if (a[0] === '-list') { fs.writeFileSync('.child-pid', String(process.pid)); setTimeout(() => {}, 20000); }
else if (a[0] === '-showsdks') process.stdout.write('x'.repeat(4096));
else process.stdout.write(JSON.stringify({args:a,cwd:process.cwd()}));
`;
  for (const name of ['xcodebuild', 'xcrun']) fs.writeFileSync(path.join(tools, name), fake, { mode: 0o755 });
  const server = spawn('python3', [path.join(f.app, 'scripts/platform/macos/xcode-bridge.py'), '--session', session, '--bind', '127.0.0.1', '--port', '0', '--tool-root', tools, '--timeout', '0.4', '--output-limit', '2048', '--mount', host1, f.app, '--mount', host2, container2], { env: f.env, stdio: ['ignore', 'pipe', 'pipe'] });
  let logs = ''; server.stdout.on('data', d => logs += d); server.stderr.on('data', d => logs += d);
  const closed = new Promise(resolve => server.once('close', code => resolve(code)));
  const watchdog = setTimeout(() => server.kill('SIGKILL'), 12000);
  t.after(async () => { clearTimeout(watchdog); if (server.exitCode === null) server.kill('SIGTERM'); await closed; });
  const manifestFile = path.join(session, 'manifest.json');
  const deadline = Date.now() + 4000;
  while (!fs.existsSync(manifestFile) && server.exitCode === null && Date.now() < deadline) await new Promise(r => setTimeout(r, 10));
  assert.ok(fs.existsSync(manifestFile), logs);
  const manifest = JSON.parse(fs.readFileSync(manifestFile));
  const token = fs.readFileSync(path.join(session, 'token'), 'utf8').trim();
  const request = (body, extra = {}) => new Promise((resolve, reject) => {
    const data = typeof body === 'string' ? body : body === undefined ? '' : JSON.stringify(body);
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), Authorization: `Bearer ${token}`, ...extra.headers };
    const req = http.request({ host: '127.0.0.1', port: manifest.port, path: extra.path || '/run', method: extra.method || 'POST', headers }, response => {
      const chunks = []; response.on('data', d => chunks.push(d)); response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', error => reject(new Error(error.message + '\n' + logs)));  req.setTimeout(3000, () => req.destroy(new Error('HTTP test timed out'))); req.end(data);
  });
  const command = (args = ['-version'], extra = {}) => ({ version: 1, command: 'xcodebuild', args, cwd: f.app, ...extra });
  const client = (name, args = [], extra = {}) => new Promise((resolve, reject) => {
    const child = spawn(name === '--health' ? process.execPath : path.join(f.app, 'docker/xcode-shims', name), name === '--health' ? [path.join(f.app, 'docker/xcode-shims/bridge-client.mjs'), '--health'] : args, { cwd: f.app, env: { ...f.env, CODEXSHELL_XCODE: '1', CODEXSHELL_XCODE_HOST: '127.0.0.1', CODEXSHELL_XCODE_PORT: String(manifest.port), CODEXSHELL_XCODE_SESSION_DIR: session, ...extra } });
    const out = [], err = []; child.stdout.on('data', d => out.push(d)); child.stderr.on('data', d => err.push(d));
    const timer = setTimeout(() => child.kill('SIGKILL'), 4000);
    child.once('error', reject); child.once('close', code => { clearTimeout(timer); resolve({ code, stdout: Buffer.concat(out), stderr: Buffer.concat(err) }); });
  });
  return { f, session, host1, host2, container2, manifest, token, request, command, client, closed, logs: () => logs };
}

test('AC8 authenticated real HTTP and all Node shims preserve bytes/status and exact mount map', async t => {
  const b = await bridge(t);
  assert.equal(fs.statSync(b.session).mode & 0o777, 0o700);
  for (const file of ['token', 'manifest.json']) assert.equal(fs.statSync(path.join(b.session, file)).mode & 0o777, 0o600);
  const health = await b.request(undefined, { path: '/health', method: 'GET' }); assert.equal(health.status, 200);
  assert.equal((await b.client('--health')).code, 0);
  const r = await b.client('xcodebuild', ['-version']); assert.equal(r.code, 7, r.stderr.toString() + b.logs());
  assert.deepEqual(r.stdout, Buffer.from([65,0,255,10])); assert.deepEqual(r.stderr, Buffer.from([69,0,254,10]));
  const run = await b.request(b.command(['-project', 'Project Ω.xcodeproj', '-scheme', 'literal $(touch injected)', 'build']));
  assert.equal(run.status, 200, run.body);
  const output = JSON.parse(Buffer.from(JSON.parse(run.body).stdout, 'base64'));
  assert.equal(output.cwd, b.host1); assert.ok(output.args.includes(path.join(b.host1, 'Project Ω.xcodeproj')));
  const second = await b.request(b.command(['build'], { cwd: b.container2 }));
  assert.equal(second.status, 200); assert.equal(JSON.parse(Buffer.from(JSON.parse(second.body).stdout, 'base64')).cwd, b.host2);
  for (const [name, args] of [['simctl', ['list']], ['xcrun', ['simctl', 'list']]]) { const result = await b.client(name, args); assert.equal(result.code, 0, result.stderr.toString()); assert.deepEqual(JSON.parse(result.stdout).args, ['simctl', 'list']); }
  assert.equal(fs.existsSync(path.join(b.host1, 'injected')), false);
  assert.equal((await b.client('xcodebuild', ['-version'], { CODEXSHELL_XCODE: '0' })).code, 1);
  assert.equal((await b.client('--health', [], { CODEXSHELL_XCODE: '0' })).code, 1);
  assert.equal(b.logs().includes(b.token), false);
  const stopped = await b.request({ version: 1, instance: b.manifest.instance }, { path: '/shutdown' }); assert.equal(stopped.status, 200); assert.equal(await b.closed, 0);
});

test('AC9 real bridge rejects authentication, syntax, options, lengths and escaping paths', async t => {
  const b = await bridge(t);
  for (const auth of ['', 'Bearer wrong']) assert.notEqual((await b.request(b.command(), { headers: { Authorization: auth } })).status, 200);
  for (const body of ['{bad', '{"version":1,"version":1}', JSON.stringify(b.command()) + ' ', 'x'.repeat(1024*1024+1)]) {
    const r = await b.request(body);
    if (body.endsWith(' ')) assert.equal(r.status, 200); else assert.notEqual(r.status, 200);
  }
  for (const cmd of [b.command([], { command: 'bash' }), b.command(['--unknown']), b.command(['-scheme', 'A=B']), b.command(['-jobs', '0']), b.command([], { version: 2 }), b.command([], { extra: true }), b.command([], { cwd: '/' }), b.command([], { cwd: b.f.app + '/../escape' }), b.command(['-project', 'escape/outside']), b.command(['-derivedDataPath', '/tmp/outside']), b.command(['-project', '../../outside']), b.command(['clang'], { command: 'xcrun' }), b.command(['spawn', 'booted', 'sh'], { command: 'simctl' }), b.command(['-scheme', 'a'.repeat(8193)]), b.command(Array(257).fill('build'))]) {
    const r = await b.request(cmd); assert.notEqual(r.status, 200, JSON.stringify(cmd).slice(0, 120));
  }
  assert.notEqual((await b.request(b.command(), { headers: { 'Content-Type': 'text/plain' } })).status, 200);
  assert.notEqual((await b.request(b.command(), { path: '/unknown' })).status, 200);
  assert.notEqual((await b.request({ version: 1, instance: 'foreign' }, { path: '/shutdown' })).status, 200);
  assert.equal((await b.request(undefined, { path: '/health', method: 'GET' })).status, 200);
});

test('AC9 execution timeout and output bounds reap only the owned child and leave bridge healthy', async t => {
  const b = await bridge(t);
  let r = await b.request(b.command(['-list'])); assert.notEqual(r.status, 200);
  const pid = Number(fs.readFileSync(path.join(b.host1, '.child-pid'), 'utf8')); assert.throws(() => process.kill(pid, 0), /ESRCH/);
  r = await b.request(b.command(['-showsdks'])); assert.notEqual(r.status, 200);
  assert.equal((await b.request(undefined, { path: '/health', method: 'GET' })).status, 200);
  assert.equal(b.logs().includes(b.token), false);
});
