import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { root, executable, archive, applicationFiles } from './helpers/fixtures.mjs';

function fixture(t, name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `codexshell-install-${name}-`));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const log = path.join(dir, 'network.log');
  const branch = sourceArchive(dir, 'master');
  const release = sourceArchive(dir, '0.2.0', 'v0.2.0');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, NETWORK_LOG: log, BRANCH_ARCHIVE: branch, RELEASE_ARCHIVE: release };
  mockCurl(bin);
  return { dir, bin, log, branch, release, env };
}

function sourceArchive(dir, ref, version = 'v0.1.0', mutate) {
  const prefix = `codexshell-${ref}`;
  const files = applicationFiles.filter(file => fs.existsSync(path.join(root, file)));
  const directories = new Set([prefix]);
  for (const file of files) {
    let parent = path.posix.dirname(file);
    while (parent !== '.') {
      directories.add(`${prefix}/${parent}`);
      parent = path.posix.dirname(parent);
    }
  }
  let entries = [
    ...[...directories].sort().map(name => ({ name: `${name}/`, type: '5', mode: 0o755 })),
    ...files.map(file => ({
      name: `${prefix}/${file}`,
      mode: file === 'VERSION' ? 0o644 : 0o600,
      content: file === 'VERSION' ? `${version}\n` : fs.readFileSync(path.join(root, file)),
    })),
  ];
  if (mutate) entries = mutate(entries, prefix);
  const output = path.join(dir, `${ref}-${Math.random().toString(16).slice(2)}.tar.gz`);
  archive(output, entries);
  return output;
}

function mockCurl(bin, apiTag = '') {
  executable(path.join(bin, 'curl'), `
output=''; url="\${!#}"
printf '%s\n' "$@" >> "$NETWORK_LOG"
while (( $# )); do
  case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac
done
case "$url" in
  */releases/latest) printf '{"tag_name":"%s"}\n' "\${API_TAG:-${apiTag}}" > "$output" ;;
  */refs/tags/*) cp "$RELEASE_ARCHIVE" "$output" ;;
  */refs/heads/master) cp "$BRANCH_ARCHIVE" "$output" ;;
  *) exit 22 ;;
esac`);
}

function mockWget(bin) {
  executable(path.join(bin, 'wget'), `
output=''; url="\${!#}"
printf '%s\n' "$@" >> "$NETWORK_LOG"
for arg in "$@"; do case "$arg" in --output-document=*) output="\${arg#*=}" ;; esac; done
case "$url" in
  */releases/latest) printf '{"tag_name":"v0.2.0"}\n' > "$output" ;;
  */refs/tags/v0.2.0) cp "$RELEASE_ARCHIVE" "$output" ;;
  *) exit 22 ;;
esac`);
}

function run(f, target, input = '', extra = {}) {
  const args = [path.join(root, 'install.sh')];
  if (target !== undefined) args.push(target);
  return spawnSync('bash', args, { cwd: f.dir, env: { ...f.env, ...extra }, input, encoding: 'utf8', timeout: 15000 });
}

test('AC1 fallback installs default destination atomically with normalized modes', t => {
  const f = fixture(t, 'fresh');
  const result = run(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const target = path.join(f.dir, 'codexshell');
  assert.match(result.stdout, /CodexShell master is installed/);
  assert.equal(spawnSync('bash', [path.join(target, 'start.sh'), '--version'], { encoding: 'utf8' }).stdout.trim(), 'v0.1.0');
  assert.ok(fs.statSync(path.join(target, 'install.sh')).mode & 0o111);
  assert.equal(fs.statSync(path.join(target, 'start.sh')).mode & 0o777, 0o755);
  assert.equal(fs.statSync(path.join(target, 'VERSION')).mode & 0o777, 0o644);
  assert.equal(fs.statSync(path.join(target, 'scripts')).mode & 0o777, 0o755);
  assert.equal(fs.statSync(path.join(target, 'scripts/lib-menu.sh')).mode & 0o111, 0);
  assert.equal(fs.existsSync(path.join(target, 'config')), false);
  assert.equal(fs.existsSync(path.join(target, '.git')), false);
  const log = fs.readFileSync(f.log, 'utf8');
  assert.match(log, /refs\/heads\/master/);
  assert.match(log, /--max-time\n60/);
  assert.match(log, /--max-filesize\n26214400/);
});

test('AC2 valid release is preferred and wget has the same install path', t => {
  const f = fixture(t, 'wget');
  fs.unlinkSync(path.join(f.bin, 'curl'));
  mockWget(f.bin);
  const bashEnv = path.join(f.dir, 'bash-env');
  fs.writeFileSync(bashEnv, 'command() { if [[ "$1" == -v && "${2:-}" == curl ]]; then return 1; fi; builtin command "$@"; }\n');
  const target = path.join(f.dir, 'custom target');
  const result = run(f, target, '', { BASH_ENV: bashEnv });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /CodexShell v0\.2\.0 is installed/);
  assert.equal(fs.readFileSync(path.join(target, 'VERSION'), 'utf8'), 'v0.2.0\n');
  const log = fs.readFileSync(f.log, 'utf8');
  assert.match(log, /releases\/latest/);
  assert.match(log, /refs\/tags\/v0\.2\.0/);
  assert.match(log, /--no-config/);
  assert.match(log, /--https-only/);
  assert.doesNotMatch(log, /refs\/heads/);
});

test('AC4 non-empty destination requires explicit consent and preserves local data', t => {
  const f = fixture(t, 'overlay');
  const target = path.join(f.dir, 'existing');
  fs.mkdirSync(target);
  fs.writeFileSync(path.join(target, 'local.txt'), 'keep\n');
  for (const input of ['', '\n', 'n\n']) {
    const result = run(f, target, input);
    assert.equal(result.status, 1);
    assert.equal(fs.readFileSync(path.join(target, 'local.txt'), 'utf8'), 'keep\n');
    assert.equal(fs.existsSync(path.join(target, 'start.sh')), false);
  }
  const accepted = run(f, target, 'y\n');
  assert.equal(accepted.status, 0, accepted.stderr + accepted.stdout);
  assert.equal(fs.readFileSync(path.join(target, 'local.txt'), 'utf8'), 'keep\n');
  assert.equal(fs.existsSync(path.join(target, 'start.sh')), true);
  assert.equal(fs.readdirSync(target).some(name => name.startsWith('.codexshell-install')), false);
});

test('AC3 hostile archive types and paths are rejected before target writes', t => {
  const cases = {
    traversal: (entries, prefix) => [...entries, { name: `${prefix}/../outside`, content: 'bad' }],
    absolute: entries => [...entries, { name: '/absolute', content: 'bad' }],
    symlink: (entries, prefix) => [...entries, { name: `${prefix}/link`, type: '2', link: '/tmp' }],
    hardlink: (entries, prefix) => [...entries, { name: `${prefix}/link`, type: '1', link: `${prefix}/VERSION` }],
    special: (entries, prefix) => [...entries, { name: `${prefix}/device`, type: '3' }],
    rootless: (entries, prefix) => entries.filter(entry => entry.name !== `${prefix}/`),
    duplicate: entries => [...entries, { ...entries.find(entry => entry.name.endsWith('/VERSION')) }],
    missing: entries => entries.filter(entry => !entry.name.endsWith('/start.sh')),
    wrongRoot: entries => entries.map(entry => ({ ...entry, name: entry.name.replace(/^codexshell-master/, 'other-master') })),
  };
  for (const [name, mutate] of Object.entries(cases)) {
    const f = fixture(t, name);
    f.env.BRANCH_ARCHIVE = sourceArchive(f.dir, 'master', 'v0.1.0', mutate);
    const target = path.join(f.dir, `target-${name}`);
    const result = run(f, target);
    assert.notEqual(result.status, 0, name);
    assert.equal(fs.existsSync(target), false, name);
  }
  const corrupt = fixture(t, 'corrupt');
  corrupt.env.BRANCH_ARCHIVE = path.join(corrupt.dir, 'corrupt.tar.gz');
  fs.writeFileSync(corrupt.env.BRANCH_ARCHIVE, 'not gzip');
  assert.notEqual(run(corrupt, path.join(corrupt.dir, 'corrupt-target')).status, 0);
});

test('AC4 symlink destinations and mid-overlay failures cannot overwrite outside data', t => {
  const f = fixture(t, 'safety');
  const outside = path.join(f.dir, 'outside');
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'sentinel'), 'safe\n');
  const linked = path.join(f.dir, 'linked');
  fs.symlinkSync(outside, linked);
  assert.notEqual(run(f, linked).status, 0);
  assert.equal(fs.readFileSync(path.join(outside, 'sentinel'), 'utf8'), 'safe\n');
  assert.notEqual(run(f, path.join(linked, 'nested')).status, 0);
  assert.equal(fs.existsSync(path.join(outside, 'nested')), false);

  const target = path.join(f.dir, 'overlay');
  fs.mkdirSync(target);
  fs.writeFileSync(path.join(target, 'start.sh'), 'original\n');
  fs.writeFileSync(path.join(target, 'keep'), 'keep\n');
  const realMv = path.join(f.bin, 'real-mv');
  fs.symlinkSync('/bin/mv', realMv);
  executable(path.join(f.bin, 'mv'), `
last="\${!#}"
if [[ "$last" == "$FAULT_TARGET/VERSION" && ! -e "$FAULT_MARKER" ]]; then : > "$FAULT_MARKER"; exit 73; fi
exec "$REAL_MV" "$@"`);
  const result = run(f, target, 'y\n', { FAULT_TARGET: target, FAULT_MARKER: path.join(f.dir, 'failed'), REAL_MV: realMv });
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(path.join(target, 'start.sh'), 'utf8'), 'original\n');
  assert.equal(fs.readFileSync(path.join(target, 'keep'), 'utf8'), 'keep\n');
  assert.equal(fs.existsSync(path.join(target, 'VERSION')), false);
});

test('AC4 TERM during overlay restores prior files and removes installer state', t => {
  const f = fixture(t, 'term');
  const target = path.join(f.dir, 'overlay');
  fs.mkdirSync(target);
  fs.writeFileSync(path.join(target, 'start.sh'), 'original\n');
  const realMv = path.join(f.bin, 'real-mv');
  fs.symlinkSync('/bin/mv', realMv);
  executable(path.join(f.bin, 'mv'), `
last="\${!#}"
if [[ "$last" == "$FAULT_TARGET/VERSION" && ! -e "$FAULT_MARKER" ]]; then
  : > "$FAULT_MARKER"; kill -TERM "$PPID"; exit 73
fi
exec "$REAL_MV" "$@"`);
  const result = run(f, target, 'y\n', { FAULT_TARGET: target, FAULT_MARKER: path.join(f.dir, 'term'), REAL_MV: realMv });
  assert.equal(result.status, 143, result.stderr);
  assert.equal(fs.readFileSync(path.join(target, 'start.sh'), 'utf8'), 'original\n');
  assert.equal(fs.existsSync(path.join(target, 'VERSION')), false);
  assert.equal(fs.readdirSync(target).some(name => name.startsWith('.codexshell-install')), false);
});

test('AC4 hardlinks, lock contention and fresh publication races stay contained', t => {
  const f = fixture(t, 'races');
  const outside = path.join(f.dir, 'outside-version');
  fs.writeFileSync(outside, 'outside\n');
  const hardTarget = path.join(f.dir, 'hard-target');
  fs.mkdirSync(hardTarget);
  fs.linkSync(outside, path.join(hardTarget, 'VERSION'));
  const hardResult = run(f, hardTarget, 'y\n');
  assert.equal(hardResult.status, 0, hardResult.stderr);
  assert.equal(fs.readFileSync(outside, 'utf8'), 'outside\n');
  assert.equal(fs.readFileSync(path.join(hardTarget, 'VERSION'), 'utf8'), 'v0.1.0\n');

  const locked = path.join(f.dir, 'locked');
  fs.mkdirSync(path.join(locked, '.codexshell-install.lock'), { recursive: true });
  fs.writeFileSync(path.join(locked, '.codexshell-install.lock', 'owner'), 'other\n');
  assert.notEqual(run(f, locked, 'y\n').status, 0);
  assert.equal(fs.readFileSync(path.join(locked, '.codexshell-install.lock', 'owner'), 'utf8'), 'other\n');

  const fresh = path.join(f.dir, 'fresh-race');
  const realMv = path.join(f.bin, 'race-real-mv');
  fs.symlinkSync('/bin/mv', realMv);
  executable(path.join(f.bin, 'mv'), `
last="\${!#}"
if [[ "$last" == "$RACE_TARGET" && ! -e "$RACE_MARKER" ]]; then
  : > "$RACE_MARKER"; mkdir "$RACE_TARGET"; printf 'other\\n' > "$RACE_TARGET/sentinel"
fi
exec "$REAL_MV" "$@"`);
  const raced = run(f, fresh, '', { RACE_TARGET: fresh, RACE_MARKER: path.join(f.dir, 'race-fired'), REAL_MV: realMv });
  assert.notEqual(raced.status, 0);
  assert.equal(fs.readFileSync(path.join(fresh, 'sentinel'), 'utf8'), 'other\n');
  assert.equal(fs.readdirSync(fresh).some(name => name.startsWith('.codexshell-install.')), false);
});

test('AC1/AC2 invalid usage and missing download clients make no target changes', t => {
  const f = fixture(t, 'preconditions');
  const invalid = spawnSync('bash', [path.join(root, 'install.sh'), 'one', 'two'], { cwd: f.dir, env: f.env, encoding: 'utf8' });
  assert.equal(invalid.status, 2);
  assert.equal(fs.existsSync(path.join(f.dir, 'one')), false);
  const bashEnv = path.join(f.dir, 'bash-env');
  fs.writeFileSync(bashEnv, 'command() { if [[ "$1" == -v && ( "${2:-}" == curl || "${2:-}" == wget ) ]]; then return 1; fi; builtin command "$@"; }\n');
  const target = path.join(f.dir, 'missing-client');
  const result = run(f, target, '', { BASH_ENV: bashEnv });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /curl or wget is required/);
  assert.equal(fs.existsSync(target), false);
});

test('AC5 updater manifest and README ship the bootstrap command', () => {
  const updater = fs.readFileSync(path.join(root, 'scripts/update.sh'), 'utf8');
  const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
  assert.match(updater, /required=\(install\.sh start\.sh VERSION/);
  assert.match(readme, /raw\.githubusercontent\.com\/boboshko\/codexshell\/master\/install\.sh \| bash/);
});
