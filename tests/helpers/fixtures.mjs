import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

export const root = fileURLToPath(new URL('../..', import.meta.url));
export function sandbox(t, prefix = 'test') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `codexshell-${prefix}-`));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const app = path.join(dir, 'codexshell');
  fs.mkdirSync(app);
  for (const file of ['start.sh', 'VERSION', 'README.md', 'CHANGELOG.md']) {
    if (fs.existsSync(path.join(root, file))) fs.copyFileSync(path.join(root, file), path.join(app, file));
  }
  fs.cpSync(path.join(root, 'scripts'), path.join(app, 'scripts'), { recursive: true });
  fs.cpSync(path.join(root, 'docker'), path.join(app, 'docker'), { recursive: true });
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const env = { ...process.env, TERM: 'dumb', CODEXSHELL_NO_UPDATE_CHECK: '1', PATH: `${bin}:${process.env.PATH}` };
  return { dir, app, bin, env };
}
export function executable(file, text) {
  fs.writeFileSync(file, `#!/usr/bin/env bash\nset -euo pipefail\n${text}\n`, { mode: 0o755 });
}
export function bash(f, text, extra = {}) {
  return spawnSync('bash', ['-c', text, 'codexshell-test', f.app], { cwd: f.app, env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 15000 });
}
export function start(f, input = '', args = [], extra = {}) {
  return spawnSync('bash', [path.join(f.app, 'start.sh'), ...args], { cwd: f.app, env: { ...f.env, ...extra }, input, encoding: 'utf8', timeout: 15000 });
}
export function archive(file, entries) {
  const blocks = [];
  for (const entry of entries) {
    const header = Buffer.alloc(512);
    const name = entry.name;
    if (Buffer.byteLength(name) > 100) throw new Error('Fixture path too long');
    header.write(name, 0, 100);
    const data = Buffer.from(entry.content || '');
    const octal = (offset, length, value) => header.write(value.toString(8).padStart(length - 1, '0') + '\0', offset, length);
    octal(100, 8, entry.mode ?? 0o644);
    octal(108, 8, 0);
    octal(116, 8, 0);
    octal(124, 12, data.length);
    octal(136, 12, 0);
    header.fill(' ', 148, 156);
    header.write(entry.type || '0', 156, 1);
    if (entry.link) header.write(entry.link, 157, 100);
    header.write('ustar\0', 257, 6);
    header.write('00', 263, 2);
    const sum = header.reduce((total, byte) => total + byte, 0);
    header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8);
    blocks.push(header, data);
    if (data.length % 512) blocks.push(Buffer.alloc(512 - data.length % 512));
  }
  blocks.push(Buffer.alloc(1024));
  fs.writeFileSync(file, gzipSync(Buffer.concat(blocks)));
}
export const applicationFiles = ['start.sh', 'VERSION', 'scripts/lib-menu.sh', 'scripts/lib-version.sh', 'scripts/lib-update.sh', 'scripts/update.sh', 'docker/Dockerfile', 'docker/entrypoint.sh', 'docker/codex-session.sh', 'docker/firewall.sh', 'docker/allowed-domains.txt', 'README.md', 'CHANGELOG.md'];
export function releaseEntries(app, version = 'v0.2.0') {
  const prefix = `codexshell-${version.slice(1)}/`;
  const directories = [{ name: prefix, type: '5', mode: 0o755 }, { name: `${prefix}scripts/`, type: '5', mode: 0o755 }, { name: `${prefix}docker/`, type: '5', mode: 0o755 }];
  return [...directories, ...applicationFiles.map(file => ({ name: prefix + file, mode: file.endsWith('.sh') ? 0o755 : 0o644, content: file === 'VERSION' ? version + '\n' : fs.readFileSync(path.join(app, file)) }))];
}
export function updateCurl(f, archivePath, result = 'https://github.com/boboshko/codexshell/releases/tag/v0.2.0') {
  const log = path.join(f.dir, 'curl.log');
  executable(path.join(f.bin, 'curl'), `printf '%s\\n' "$@" >> "$CURL_LOG"\noutput=''\nwhile (( $# )); do\n  case "$1" in\n    -o|--output) output="$2"; shift 2 ;;\n    *) shift ;;\n  esac\ndone\nif [[ -n "$output" && "$output" != /dev/null ]]; then\n  [[ -n "\${FIXTURE_ARCHIVE:-}" ]] || exit 22\n  cp "$FIXTURE_ARCHIVE" "$output"\nelse\n  printf 'HTTP/2 302\\r\\nLocation: %s\\r\\n\\r\\n' "\${FIXTURE_REDIRECT:-}"\nfi`);
  f.env.CURL_LOG = log;
  f.env.FIXTURE_ARCHIVE = archivePath || '';
  f.env.FIXTURE_REDIRECT = result;
  return log;
}
