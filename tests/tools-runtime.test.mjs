import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { sandbox, executable, bash, start } from './helpers/fixtures.mjs';

function firewall(f) {
  f.env.FIREWALL_LOG = path.join(f.dir, 'firewall.log');
  f.env.DNS_LOG = path.join(f.dir, 'dns.log');
  f.env.CODEXSHELL_ALLOWLIST_FILE = path.join(f.app, 'docker/allowed-domains.txt');
  for (const name of ['iptables', 'ip6tables']) executable(path.join(f.bin, name), `printf '%s %s\\n' "${name}" "$*" >> "$FIREWALL_LOG"\n[[ "\${FAIL_ENFORCE:-0}" == 0 ]]`);
  executable(path.join(f.bin, 'getent'), `printf '%s\\n' "$2" >> "$DNS_LOG"\n[[ "\${NO_DNS:-0}" == 0 ]] || exit 2\nif [[ \"$2\" == host.docker.internal ]]; then printf '192.0.2.42 STREAM fixture\\n'; else printf '203.0.113.5 STREAM fixture\\n'; fi`);
  return (extra = {}) => bash(f, 'bash "$1/docker/firewall.sh"', extra);
}

test('AC10 firewall scopes ecosystem DNS, Xcode destination and IPv6 restrictions', t => {
  const f = sandbox(t, 'tools-firewall'); const run = firewall(f);
  let r = run(); assert.equal(r.status, 0, r.stderr);
  const baseDns = fs.readFileSync(f.env.DNS_LOG, 'utf8');
  assert.match(baseDns, /openai/); assert.doesNotMatch(baseDns, /pypi|golang|crates/);
  assert.match(fs.readFileSync(f.env.FIREWALL_LOG, 'utf8'), /ip6tables -P OUTPUT DROP/);
  fs.writeFileSync(f.env.DNS_LOG, ''); fs.writeFileSync(f.env.FIREWALL_LOG, '');
  r = run({ CODEXSHELL_ENABLED_TOOLS: 'PYTHON,GO,RUST', CODEXSHELL_XCODE: '1', CODEXSHELL_XCODE_HOST: 'host.docker.internal', CODEXSHELL_XCODE_PORT: '32145' });
  assert.equal(r.status, 0, r.stderr);
  const dns = fs.readFileSync(f.env.DNS_LOG, 'utf8');
  for (const domain of ['pypi.org', 'files.pythonhosted.org', 'proxy.golang.org', 'sum.golang.org', 'index.crates.io']) assert.ok(dns.includes(domain), domain);
  const rules = fs.readFileSync(f.env.FIREWALL_LOG, 'utf8');
  assert.match(rules, /192\.0\.2\.42.*32145|32145.*192\.0\.2\.42/);
  assert.doesNotMatch(rules, /192\.0\.2\.0\/24|0\.0\.0\.0\/0/);
});

test('AC10 no-address and enforcing-command failures stop firewall', t => {
  const f = sandbox(t, 'tools-firewall-fail'); const run = firewall(f);
  assert.notEqual(run({ NO_DNS: '1' }).status, 0);
  assert.notEqual(run({ FAIL_ENFORCE: '1' }).status, 0);
});

test('AC7 socket prompt requires explicit y; no, blank, EOF and canceled consent preserve defaults', t => {
  for (const reply of ['n\nsave\n0\n', '\nsave\n0\n', '', 'y\ncancel\n0\n']) {
    const f = sandbox(t, 'tools-socket-consent');
    const r = start(f, '5\n3\n' + reply);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr + r.stdout, /root-equivalent/);
    const file = path.join(f.app, 'config/tools.conf');
    if (fs.existsSync(file)) assert.match(fs.readFileSync(file, 'utf8'), /^TOOL_DOCKER_SOCKET=off$/m);
  }
  const f = sandbox(t, 'tools-socket-yes');
  const r = start(f, '5\n3\ny\nsave\n0\n'); assert.equal(r.status, 0, r.stderr);
  assert.match(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), /^TOOL_DOCKER_SOCKET=on$/m);
});

test('AC7 entrypoint preserves host socket metadata and retains socket GID after dropping privilege', async t => {
  const f = sandbox(t, 'tools-socket-gid');
  const socket = path.join(f.dir, 'docker.sock'); const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
  t.after(() => server.close());
  const before = fs.statSync(socket);
  f.env.ENTRY_LOG = path.join(f.dir, 'entry.log');
  for (const name of ['gosu', 'setpriv', 'chown']) executable(path.join(f.bin, name), `printf '%s %s\\n' '${name}' "$*" >> "$ENTRY_LOG"`);
  executable(path.join(f.bin, 'id'), "case \"$1\" in -u) printf '0\\n' ;; -g) printf '20\\n' ;; *) exit 1 ;; esac");
  fs.writeFileSync(path.join(f.app, 'entry-test.sh'), fs.readFileSync(path.join(f.app, 'docker/entrypoint.sh'), 'utf8').replaceAll('/var/run/docker.sock', socket));
  const r = bash(f, 'bash "$1/entry-test.sh"', { FIREWALL_MODE: 'disabled', HOST_UID: '501', HOST_GID: '20', CODEXSHELL_DOCKER_SOCKET: '1' });
  assert.equal(r.status, 0, r.stderr);
  const log = fs.readFileSync(f.env.ENTRY_LOG, 'utf8');
  assert.match(log, new RegExp(`setpriv .*--reuid 501.*--regid 20.*--groups ${before.gid}`));
  assert.doesNotMatch(log, /gosu/); assert.equal(log.includes(socket), false, 'host socket must never be chowned');
  const after = fs.statSync(socket); assert.deepEqual([after.mode, after.uid, after.gid], [before.mode, before.uid, before.gid]);
});

test('AC7 launch binds socket only when enabled, rejects missing socket and never uses privileged mode', async t => {
  const f = sandbox(t, 'tools-socket-launch');
  const socket = path.join(f.dir, 'docker.sock'); const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
  t.after(() => server.close());
  fs.writeFileSync(path.join(f.app, 'start.sh'), fs.readFileSync(path.join(f.app, 'start.sh'), 'utf8').replaceAll('/var/run/docker.sock', socket));
  f.env.DOCKER_LOG = path.join(f.dir, 'docker.log');
  f.env.DOCKER_HOST = 'unix://' + socket;
  executable(path.join(f.bin, 'docker'), `printf '%s\\n' "$*" >> "$DOCKER_LOG"\nif [[ "$1" == image ]]; then printf 'sha256:socket-fixture\\n'; fi`);
  let r = start(f, '1\n0\n'); assert.equal(r.status, 0, r.stderr);
  let log = fs.readFileSync(f.env.DOCKER_LOG, 'utf8'); assert.equal(log.includes('source=' + socket), false);
  fs.writeFileSync(path.join(f.app, 'config/tools.conf'), 'TOOL_DOCKER_SOCKET=on\n');
  fs.writeFileSync(f.env.DOCKER_LOG, '');
  r = start(f, '1\n0\n'); assert.equal(r.status, 0, r.stderr);
  log = fs.readFileSync(f.env.DOCKER_LOG, 'utf8'); assert.ok(log.includes('source=' + socket)); assert.match(log, /CODEXSHELL_DOCKER_SOCKET=1/); assert.doesNotMatch(log, /--privileged/);
  const runLine = log.split('\n').find(line => line.startsWith('run '));
  assert.ok(runLine, 'missing Docker run invocation');
  const runArgs = runLine.split(' ');
  assert.deepEqual(runArgs.filter(arg => ['CHOWN', 'DAC_OVERRIDE', 'KILL', 'SETUID', 'SETGID', 'NET_ADMIN'].includes(arg)), ['CHOWN', 'DAC_OVERRIDE', 'KILL', 'SETUID', 'SETGID', 'NET_ADMIN']);
  assert.equal(runArgs.filter(arg => arg === '--cap-drop').length, 1);
  assert.equal(runArgs.filter(arg => arg === 'ALL').length, 1);
  assert.equal(runArgs.filter(arg => arg === '--cap-add').length, 6);
  assert.equal(runArgs.filter(arg => arg === '--security-opt').length, 1);
  assert.equal(runArgs.filter(arg => arg === 'no-new-privileges').length, 1);
  for (const forbidden of ['--privileged', '--pid', '--userns']) {
    assert.equal(runArgs.some(arg => arg === forbidden || arg.startsWith(forbidden + '=')), false);
  }
  await new Promise(resolve => server.close(resolve));
  fs.writeFileSync(f.env.DOCKER_LOG, '');
  r = start(f, '1\n\n0\n'); assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(f.env.DOCKER_LOG, 'utf8').split('\n').some(l => l.startsWith('run ')), false);
});

test('AC7 socket discovery follows context precedence and rejects remote or unsafe endpoints', async t => {
  const f = sandbox(t, 'tools-socket-context'); const socket = path.join(f.dir, 'context.sock'); const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); }); t.after(() => server.close());
  executable(path.join(f.bin, 'docker'), `[[ "$1 $2" == 'context inspect' ]] || exit 97\nprintf 'unix://%s\\n' "$MOCK_SOCKET"`);
  f.env.MOCK_SOCKET = socket;
  for (const extra of [{}, { DOCKER_HOST: 'unix://' + socket }, { DOCKER_CONTEXT: 'desktop-linux', DOCKER_HOST: 'tcp://unsafe:2375' }]) {
    const r = bash(f, 'source "$1/scripts/lib-tools.sh"; tools_socket_path; printf "%s\\n" "$TOOLS_SOCKET_PATH"', extra);
    assert.equal(r.status, 0, r.stderr); assert.equal(r.stdout.trim(), socket);
  }
  for (const endpoint of ['tcp://remote:2375', 'ssh://remote', 'unix:///missing', 'unix:///tmp/bad,option']) assert.notEqual(bash(f, 'source "$1/scripts/lib-tools.sh"; tools_socket_path', { DOCKER_HOST: endpoint, DOCKER_CONTEXT: '' }).status, 0);
});

test('AC8 enabled Xcode health succeeds before privilege drop; failed health prevents Codex', t => {
  const f = sandbox(t, 'tools-xcode-health'); f.env.ENTRY_LOG = path.join(f.dir, 'health.log');
  executable(path.join(f.bin, 'id'), "case \"$1\" in -u) printf '0\\n' ;; -g) printf '20\\n' ;; esac");
  for (const name of ['chown', 'gosu']) executable(path.join(f.bin, name), `printf '%s %s\\n' '${name}' "$*" >> "$ENTRY_LOG"`);
  executable(path.join(f.bin, 'node'), `printf 'node %s\\n' "$*" >> "$ENTRY_LOG"\nexit "\${HEALTH_STATUS:-0}"`);
  const env = { FIREWALL_MODE: 'disabled', HOST_UID: '501', HOST_GID: '20', CODEXSHELL_XCODE: '1' };
  let r = bash(f, 'bash "$1/docker/entrypoint.sh"', env); assert.equal(r.status, 0, r.stderr);
  let log = fs.readFileSync(f.env.ENTRY_LOG, 'utf8'); assert.match(log, /bridge-client\.mjs --health/); assert.ok(log.indexOf('--health') < log.indexOf('gosu'));
  fs.writeFileSync(f.env.ENTRY_LOG, '');
  r = bash(f, 'bash "$1/docker/entrypoint.sh"', { ...env, HEALTH_STATUS: '1' }); assert.notEqual(r.status, 0);
  log = fs.readFileSync(f.env.ENTRY_LOG, 'utf8'); assert.doesNotMatch(log, /gosu/);
});
