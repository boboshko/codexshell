import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { root } from './fixtures.mjs';

const output = path.join(root, '.pipeline/05-test');
fs.mkdirSync(output, { recursive: true });
const shell = ['start.sh', 'scripts/lib-menu.sh', 'scripts/lib-tools.sh', 'scripts/lib-build.sh', 'scripts/lib-version.sh', 'scripts/lib-update.sh', 'scripts/update.sh', 'scripts/platform/macos/lib-xcode-bridge.sh', 'docker/install-tools.sh', 'docker/entrypoint.sh', 'docker/firewall.sh', 'docker/codex-session.sh', 'docker/xcode-shims/xcodebuild', 'docker/xcode-shims/xcrun', 'docker/xcode-shims/simctl', 'tests/test.sh', 'tests/test-auth.sh'];
const sources = [...shell, 'scripts/tools-catalog.tsv', 'scripts/platform/macos/xcode-bridge.py', 'docker/xcode-shims/bridge-client.mjs', 'docker/Dockerfile', 'docker/allowed-domains.txt'];
const snapshot = () => Object.fromEntries(sources.map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')]));
const evidence = { started: new Date().toISOString(), platform: { os: process.platform, arch: process.arch, node: process.version }, before: snapshot(), checks: [] };
function run(name, executable, args, options = {}) {
  const r = spawnSync(executable, args, { cwd: root, env: process.env, encoding: 'utf8', timeout: 60000, maxBuffer: 10*1024*1024, ...options });
  const log = `tools-${name}.log`;
  fs.writeFileSync(path.join(output, log), `${r.stdout || ''}${r.stderr || ''}${r.error ? '\n' + r.error.message : ''}`);
  evidence.checks.push({ name, command: [executable, ...args], exit: r.status, signal: r.signal, error: r.error?.message, log });
  process.stdout.write(`${name}: ${r.status === 0 ? 'PASS' : 'FAIL'} (exit ${r.status})\n`);
}
run('environment', 'bash', ['-c', 'uname -sm; bash --version | head -1; node --version; python3 --version; shellcheck --version; command -v docker || true; command -v pwsh || true']);
for (const file of shell) run(`syntax-${file.replaceAll('/', '_')}`, 'bash', ['-n', file]);
run('strict-lint', 'node', ['scripts/lint-shell.mjs', '--strict', ...shell.filter(file => file.endsWith('.sh'))]);
run('shim-shellcheck', 'shellcheck', ['--shell=bash', ...shell.filter(file => !file.endsWith('.sh'))]);
const cache = fs.mkdtempSync(path.join(os.tmpdir(), 'codexshell-qa-bytecode-'));
try { run('python-syntax', 'python3', ['-m', 'py_compile', 'scripts/platform/macos/xcode-bridge.py'], { env: { ...process.env, PYTHONPYCACHEPREFIX: cache } }); }
finally { fs.rmSync(cache, { recursive: true, force: true }); }
run('node-syntax', 'node', ['--check', 'docker/xcode-shims/bridge-client.mjs']);
run('shell', 'bash', ['tests/test.sh']);
run('auth', 'bash', ['tests/test-auth.sh']);
run('node', 'node', ['--test', ...fs.readdirSync(path.join(root, 'tests')).filter(file => file.endsWith('.test.mjs')).sort().map(file => `tests/${file}`)]);
evidence.after = snapshot();
evidence.sourcesStable = JSON.stringify(evidence.before) === JSON.stringify(evidence.after);
evidence.finished = new Date().toISOString();
fs.writeFileSync(path.join(output, 'tools-run-evidence.json'), JSON.stringify(evidence, null, 2) + '\n');
process.exitCode = evidence.sourcesStable && evidence.checks.every(check => check.exit === 0) ? 0 : 1;
