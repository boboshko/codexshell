import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { root, sandbox, executable, bash, start, archive, releaseEntries, applicationFiles, updateCurl } from './helpers/fixtures.mjs';

function appVersion(f) {
  return fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8').trim();
}
function check(f) {
  return bash(f, 'source "$1/scripts/lib-version.sh"; source "$1/scripts/lib-update.sh"; update_check "$1" "$CURRENT_VERSION"; printf "TAG=%s\\nVERSION=%s\\n" "${UPDATE_TAG:-}" "${UPDATE_VERSION:-}"', { CODEXSHELL_NO_UPDATE_CHECK: '0', CURRENT_VERSION: appVersion(f) });
}
function snapshot(app) {
  return Object.fromEntries(applicationFiles.map(file => [file, fs.existsSync(path.join(app, file)) ? crypto.createHash('sha256').update(fs.readFileSync(path.join(app, file))).digest('hex') : null]));
}
function install(f, tag = 'v0.2.0') {
  return bash(f, 'bash "$1/scripts/update.sh" "$TARGET_TAG"', { TARGET_TAG: tag });
}
function release(f, entries) {
  const file = path.join(f.dir, 'release.tar.gz');
  archive(file, entries || releaseEntries(f.app));
  updateCurl(f, file);
  return file;
}

test('version comparison is numeric, strict, and safe for shell-shaped data', t => {
  const f = sandbox(t, 'version-compare');
  const cases = [['v0.10.0', 'v0.9.9', 0], ['v10.0.0', 'v9.99.99', 0], ['v0.1.0', 'v0.1.0', 1], ['v0.0.9', 'v0.1.0', 1], ['v1.0.0-rc1', 'v0.1.0', 2], ['v01.0.0', 'v0.1.0', 2], ['$(touch injected)', 'v0.1.0', 2], ['', 'v0.1.0', 2]];
  for (const [candidate, current, expected] of cases) {
    const r = bash(f, 'source "$1/scripts/lib-version.sh"; version_is_newer "$CANDIDATE" "$CURRENT"', { CANDIDATE: candidate, CURRENT: current });
    assert.equal(r.status, expected, `${candidate} / ${current}: ${r.stderr}`);
  }
  assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
});

test('sourcing update/version libraries performs no I/O or network', t => {
  const f = sandbox(t, 'source-purity');
  const log = updateCurl(f);
  const result = bash(f, 'source "$1/scripts/lib-version.sh"; source "$1/scripts/lib-update.sh"');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(f.app, 'config')), false);
  assert.equal(fs.existsSync(log), false);
});

test('newer release check is fixed-source, bounded, cached, and shown in the menu', t => {
  const f = sandbox(t, 'release-check');
  const log = updateCurl(f);
  const result = check(f);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /TAG=v0\.2\.0/);
  const args = fs.readFileSync(log, 'utf8').trim().split('\n');
  assert.ok(args.includes('https://github.com/boboshko/codexshell/releases/latest'));
  const timeout = args.findIndex(x => x === '--max-time');
  assert.ok(timeout >= 0 && Number(args[timeout + 1]) <= 3);
  assert.equal(args.includes('-L') || args.includes('--location'), false);
  const before = fs.readFileSync(log, 'utf8');
  assert.match(check(f).stdout, /TAG=v0\.2\.0/);
  assert.equal(fs.readFileSync(log, 'utf8'), before);
  assert.match(start(f, '0\n', [], { CODEXSHELL_NO_UPDATE_CHECK: '0' }).stdout, /Update to v0\.2\.0/);
});

test('equal, older, foreign, malformed and failed checks never offer an update', t => {
  for (const redirect of [null, 'https://github.com/boboshko/codexshell/releases/tag/v0.0.9', 'https://example.com/releases/tag/v9.0.0', 'https://github.com/boboshko/claudeshell/releases/tag/v9.0.0', '$(touch injected)', 'https://github.com/boboshko/codexshell/releases/tag/v0.2.0-rc1', '']) {
    const f = sandbox(t, 'release-invalid');
    const releaseRedirect = redirect ?? `https://github.com/boboshko/codexshell/releases/tag/${appVersion(f)}`;
    const log = updateCurl(f, undefined, releaseRedirect);
    const result = check(f);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /TAG=\n/);
    const before = fs.readFileSync(log, 'utf8');
    check(f);
    assert.equal(fs.readFileSync(log, 'utf8'), before, 'negative check must be cached');
    assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
  }
  const f = sandbox(t, 'offline');
  executable(path.join(f.bin, 'curl'), 'exit 28');
  assert.equal(check(f).status, 0);
  assert.doesNotMatch(start(f, '0\n', [], { CODEXSHELL_NO_UPDATE_CHECK: '0' }).stdout, /Update to/);
});

test('corrupt, expired, future, and shell-shaped caches are treated as data', t => {
  for (const content of ['garbage\nv9.0.0\n', '0\nv9.0.0\n', '999999999999999999999999\nv9.0.0\n', '$(touch injected)\nv9.0.0\n', `${Math.floor(Date.now() / 1000) + 10000}\nv9.0.0\n`]) {
    const f = sandbox(t, 'cache-invalid');
    fs.mkdirSync(path.join(f.app, 'config'));
    fs.writeFileSync(path.join(f.app, 'config/update-cache'), content);
    updateCurl(f, undefined, 'https://github.com/boboshko/codexshell/releases/tag/v0.3.0');
    const result = check(f);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /TAG=v0\.3\.0/);
    assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
  }
});

test('missing curl leaves ordinary operations usable', t => {
  const f = sandbox(t, 'missing-curl');
  const result = bash(f, 'command() { if [[ "$1" == -v && "${2:-}" == curl ]]; then return 1; fi; builtin command "$@"; }; source "$1/scripts/lib-version.sh"; source "$1/scripts/lib-update.sh"; update_check "$1" "$CURRENT_VERSION"; printf "TAG=%s\\n" "${UPDATE_TAG:-}"', { CURRENT_VERSION: appVersion(f) });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /TAG=\n/);
});

test('exact release installation preserves protected and unknown local data', t => {
  const f = sandbox(t, 'update-success');
  const protectedFiles = ['config/firewall', 'config/folders.txt', '.pipeline/state.json', '.agents/custom', '.codex/auth.json', '.git/HEAD', 'custom-project/file.txt'];
  for (const file of protectedFiles) {
    fs.mkdirSync(path.dirname(path.join(f.app, file)), { recursive: true });
    fs.writeFileSync(path.join(f.app, file), `sentinel:${file}\n`);
  }
  const entries = releaseEntries(f.app);
  entries.find(e => e.name.endsWith('/start.sh')).content = fs.readFileSync(path.join(f.app, 'start.sh'), 'utf8') + '\n:\n';
  entries.push({ name: 'codexshell-0.2.0/config/firewall', content: 'overwrite-attempt\n' });
  entries.push({ name: 'codexshell-0.2.0/unknown', content: 'ignore\n' });
  release(f, entries);
  const result = install(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8'), 'v0.2.0\n');
  assert.match(start(f, '', ['--version']).stdout, /v0\.2\.0/);
  for (const file of protectedFiles) assert.equal(fs.readFileSync(path.join(f.app, file), 'utf8'), `sentinel:${file}\n`);
  assert.equal(fs.existsSync(path.join(f.app, 'unknown')), false);
  const log = fs.readFileSync(f.env.CURL_LOG, 'utf8');
  assert.match(log, /https:\/\/codeload\.github\.com\/boboshko\/codexshell\/tar\.gz\/refs\/tags\/v0\.2\.0/);
  assert.doesNotMatch(log, /refs\/heads|\/main/);
});

test('menu selection installs a cached newer release and restarts with the new version', t => {
  const f = sandbox(t, 'menu-update');
  release(f);
  fs.mkdirSync(path.join(f.app, 'config'));
  fs.writeFileSync(path.join(f.app, 'config/update-cache'), `${Math.floor(Date.now() / 1000)}\nv0.2.0\n`);
  const result = start(f, '4\n0\n', [], { CODEXSHELL_NO_UPDATE_CHECK: '0' });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8'), 'v0.2.0\n');
  assert.match(result.stdout, /v0\.2\.0/);
});

test('invalid input, download failure, and corrupt archives preserve the installed app', t => {
  const f = sandbox(t, 'update-failure');
  const currentVersion = appVersion(f);
  const before = snapshot(f.app);
  updateCurl(f);
  assert.notEqual(install(f, 'v0.2.0;touch injected').status, 0);
  assert.deepEqual(snapshot(f.app), before);
  assert.notEqual(install(f).status, 0);
  const bad = path.join(f.dir, 'bad.tar.gz');
  fs.writeFileSync(bad, 'not an archive');
  updateCurl(f, bad);
  assert.notEqual(install(f).status, 0);
  assert.deepEqual(snapshot(f.app), before);
  assert.equal(fs.existsSync(path.join(f.app, 'injected')), false);
  assert.equal(start(f, '', ['--version']).stdout.trim(), currentVersion);
});

test('unsafe or mismatched release archives never modify app or outside sentinels', t => {
  const scenarios = ['version', 'missing', 'traversal', 'absolute', 'symlink', 'hardlink', 'duplicate', 'root'];
  for (const scenario of scenarios) {
    const f = sandbox(t, `unsafe-${scenario}`);
    const sentinel = path.join(f.dir, 'outside');
    fs.writeFileSync(sentinel, 'untouched');
    let entries = releaseEntries(f.app);
    if (scenario === 'version') entries.find(e => e.name.endsWith('/VERSION')).content = 'v9.0.0\n';
    if (scenario === 'missing') entries = entries.filter(e => !e.name.endsWith('/start.sh'));
    if (scenario === 'traversal') entries.push({ name: 'codexshell-0.2.0/../../outside', content: 'bad' });
    if (scenario === 'absolute') entries.push({ name: sentinel, content: 'bad' });
    if (scenario === 'symlink') entries.push({ name: 'codexshell-0.2.0/link', type: '2', link: sentinel });
    if (scenario === 'hardlink') entries.push({ name: 'codexshell-0.2.0/link', type: '1', link: sentinel });
    if (scenario === 'duplicate') entries.push({ name: 'codexshell-0.2.0/VERSION', content: 'v0.2.0\n' });
    if (scenario === 'root') entries = entries.map(e => ({ ...e, name: e.name.replace('codexshell-0.2.0', 'other-0.2.0') }));
    release(f, entries);
    const before = snapshot(f.app);
    const result = install(f);
    assert.notEqual(result.status, 0, `${scenario}: ${result.stdout}`);
    assert.deepEqual(snapshot(f.app), before, scenario);
    assert.equal(fs.readFileSync(sentinel, 'utf8'), 'untouched', scenario);
  }
});

test('symlinked installation destinations cannot redirect update writes', t => {
  const f = sandbox(t, 'destination-link');
  const currentVersion = appVersion(f);
  release(f);
  const outside = path.join(f.dir, 'outside.sh');
  fs.writeFileSync(outside, 'untouched');
  fs.unlinkSync(path.join(f.app, 'start.sh'));
  fs.symlinkSync(outside, path.join(f.app, 'start.sh'));
  assert.notEqual(install(f).status, 0);
  assert.equal(fs.readFileSync(outside, 'utf8'), 'untouched');
  assert.equal(fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8'), `${currentVersion}\n`);
});

test('mid-install write failure rolls back every prior replacement', t => {
  const f = sandbox(t, 'rollback');
  const currentVersion = appVersion(f);
  const entries = releaseEntries(f.app);
  entries.find(e => e.name.endsWith('/start.sh')).content = fs.readFileSync(path.join(f.app, 'start.sh'), 'utf8') + '\n:\n';
  release(f, entries);
  const before = snapshot(f.app);
  const marker = path.join(f.dir, 'write-failed');
  executable(path.join(f.bin, 'mv'), `last="\${!#}"\nif [[ "$last" == "$FAULT_APP/scripts/lib-version.sh" && ! -e "$FAULT_MARKER" ]]; then\n  : > "$FAULT_MARKER"\n  exit 73\nfi\nexec /bin/mv "$@"`);
  f.env.FAULT_APP = f.app;
  f.env.FAULT_MARKER = marker;
  const result = install(f);
  assert.notEqual(result.status, 0);
  assert.equal(fs.existsSync(marker), true, 'fault must occur after earlier files were replaced');
  assert.deepEqual(snapshot(f.app), before);
  assert.equal(start(f, '', ['--version']).stdout.trim(), currentVersion);
  assert.equal(fs.readdirSync(f.app).some(name => name.startsWith('.codexshell-update')), false);
});

test('nonwritable application directory fails before changing application files', { skip: process.getuid?.() === 0 ? 'Root bypasses directory write permissions; run as an ordinary user' : false }, t => {
  const f = sandbox(t, 'permissions');
  release(f);
  const before = snapshot(f.app);
  const initialMode = fs.statSync(f.app).mode & 0o777;
  try {
    fs.chmodSync(f.app, 0o555);
    const result = install(f);
    assert.notEqual(result.status, 0);
    assert.deepEqual(snapshot(f.app), before);
  } finally {
    fs.chmodSync(f.app, initialMode);
  }
});

test('cache expires exactly at 3600 seconds and oversized cache is ignored', t => {
  for (const [age, expected] of [[3599, 'v0.2.0'], [3600, 'v0.3.0']]) {
    const f = sandbox(t, 'cache-boundary');
    fs.mkdirSync(path.join(f.app, 'config'));
    fs.writeFileSync(path.join(f.app, 'config/update-cache'), `${1700000000 - age}\nv0.2.0\n`);
    executable(path.join(f.bin, 'date'), "printf '1700000000\\n'");
    updateCurl(f, undefined, 'https://github.com/boboshko/codexshell/releases/tag/v0.3.0');
    assert.match(check(f).stdout, new RegExp(`TAG=${expected.replaceAll('.', '\\.')}`));
  }
  const f = sandbox(t, 'large-cache');
  fs.mkdirSync(path.join(f.app, 'config'));
  fs.writeFileSync(path.join(f.app, 'config/update-cache'), 'x'.repeat(1024 * 1024));
  updateCurl(f);
  assert.match(check(f).stdout, /TAG=v0\.2\.0/);
});

test('installer lock and missing dependency fail before downloading or changing files', t => {
  const f = sandbox(t, 'installer-preconditions');
  const log = updateCurl(f);
  const before = snapshot(f.app);
  const lock = path.join(f.app, '.codexshell-update.lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'owner'), 'other-updater');
  assert.notEqual(install(f).status, 0);
  assert.equal(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), 'other-updater');
  assert.equal(fs.existsSync(log), false);
  fs.rmSync(lock, { recursive: true });
  const envFile = path.join(f.dir, 'missing-dependency');
  fs.writeFileSync(envFile, 'command() { if [[ "$1" == -v && "${2:-}" == tar ]]; then return 1; fi; builtin command "$@"; }\n');
  f.env.BASH_ENV = envFile;
  const result = install(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing dependency: tar/);
  assert.deepEqual(snapshot(f.app), before);
  assert.equal(fs.existsSync(log), false);
});

test('TERM during replacement rolls back prior writes and cleans private staging', t => {
  const f = sandbox(t, 'installer-term');
  const currentVersion = appVersion(f);
  release(f);
  const before = snapshot(f.app);
  executable(path.join(f.bin, 'mv'), `last="\${!#}"\nif [[ "$last" == "$FAULT_APP/scripts/lib-version.sh" && ! -e "$FAULT_MARKER" ]]; then\n  : > "$FAULT_MARKER"\n  kill -TERM "$PPID"\n  exit 73\nfi\nexec /bin/mv "$@"`);
  f.env.FAULT_APP = f.app;
  f.env.FAULT_MARKER = path.join(f.dir, 'term-sent');
  const result = install(f);
  assert.equal(result.status, 143, result.stderr);
  assert.equal(fs.existsSync(f.env.FAULT_MARKER), true);
  assert.deepEqual(snapshot(f.app), before);
  assert.equal(start(f, '', ['--version']).stdout.trim(), currentVersion);
  assert.equal(fs.readdirSync(f.app).some(name => name.startsWith('.codexshell-update')), false);
});

test('Git source archives exclude local toolkit links and install without creating commits', t => {
  const f = sandbox(t, 'git-source');
  const source = path.join(f.dir, 'source');
  fs.cpSync(f.app, source, { recursive: true });
  fs.writeFileSync(path.join(source, 'VERSION'), 'v0.2.0\n');
  fs.copyFileSync(path.join(root, '.gitattributes'), path.join(source, '.gitattributes'));
  fs.mkdirSync(path.join(source, '.agents'));
  fs.symlinkSync('../local-toolkit', path.join(source, '.agents/skills'));
  const git = (...args) => spawnSync('git', ['-C', source, ...args], { encoding: 'utf8', timeout: 10000 });
  assert.equal(git('init', '--quiet').status, 0);
  assert.equal(git('add', '.').status, 0);
  assert.match(git('ls-files', '--stage', '.agents/skills').stdout, /^120000 /);
  const tree = git('write-tree');
  assert.equal(tree.status, 0, tree.stderr);
  const packed = spawnSync('git', ['-C', source, 'archive', '--format=tar', '--prefix=codexshell-0.2.0/', tree.stdout.trim()], { timeout: 10000, maxBuffer: 10 * 1024 * 1024 });
  assert.equal(packed.status, 0, packed.stderr?.toString());
  const file = path.join(f.dir, 'git-source.tar.gz');
  fs.writeFileSync(file, gzipSync(packed.stdout));
  const listing = spawnSync('tar', ['-tzf', file], { encoding: 'utf8', timeout: 10000 });
  assert.equal(listing.status, 0, listing.stderr);
  assert.doesNotMatch(listing.stdout, /\.agents(?:\/|\n)/);
  assert.equal(fs.lstatSync(path.join(source, '.agents/skills')).isSymbolicLink(), true);
  assert.notEqual(git('rev-parse', '--verify', 'HEAD').status, 0, 'no temporary commit is permitted');
  updateCurl(f, file);
  const installed = install(f);
  assert.equal(installed.status, 0, installed.stderr + installed.stdout);
  assert.equal(fs.readFileSync(path.join(f.app, 'VERSION'), 'utf8'), 'v0.2.0\n');
});

test('AC11 nested tool payload and executable shims install while optional docs stay absent', t => {
  const f = sandbox(t, 'tools-update');
  for (const file of ['README.md', 'CHANGELOG.md']) if (fs.existsSync(path.join(f.app, file))) fs.unlinkSync(path.join(f.app, file));
  fs.mkdirSync(path.join(f.app, 'config'));
  fs.writeFileSync(path.join(f.app, 'config/tools.conf'), 'TOOL_GO=on\n');
  fs.writeFileSync(path.join(f.app, '.gitignore'), 'private-local\n');
  release(f);
  fs.rmSync(path.join(f.app, 'scripts/platform'), { recursive: true });
  fs.rmSync(path.join(f.app, 'docker/xcode-shims'), { recursive: true });
  const r = install(f);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  for (const file of ['scripts/platform/macos/xcode-bridge.py', 'docker/xcode-shims/bridge-client.mjs', 'scripts/tools-catalog.tsv', 'docker/install-tools.sh']) assert.equal(fs.existsSync(path.join(f.app, file)), true, file);
  for (const name of ['xcodebuild', 'xcrun', 'simctl']) assert.ok(fs.statSync(path.join(f.app, 'docker/xcode-shims', name)).mode & 0o111, name);
  assert.equal(fs.readFileSync(path.join(f.app, 'config/tools.conf'), 'utf8'), 'TOOL_GO=on\n');
  assert.equal(fs.readFileSync(path.join(f.app, '.gitignore'), 'utf8'), 'private-local\n');
  assert.equal(fs.existsSync(path.join(f.app, 'README.md')), false);
  assert.equal(fs.existsSync(path.join(f.app, 'CHANGELOG.md')), false);
});

test('AC11 updater rejects any symlinked ancestor before writing nested tools', t => {
  const f = sandbox(t, 'tools-update-ancestor'); release(f);
  const outside = path.join(f.dir, 'outside-platform');
  fs.renameSync(path.join(f.app, 'scripts/platform'), outside);
  fs.symlinkSync(outside, path.join(f.app, 'scripts/platform'));
  const original = fs.readFileSync(path.join(outside, 'macos/xcode-bridge.py'));
  const before = snapshot(f.app);
  assert.notEqual(install(f).status, 0);
  assert.deepEqual(snapshot(f.app), before);
  assert.deepEqual(fs.readFileSync(path.join(outside, 'macos/xcode-bridge.py')), original);
});

test('AC11 failed nested install removes new directory tree and restores existing payload', t => {
  const f = sandbox(t, 'tools-update-nested-rollback'); release(f);
  fs.rmSync(path.join(f.app, 'scripts/platform'), { recursive: true });
  fs.rmSync(path.join(f.app, 'docker/xcode-shims'), { recursive: true });
  const before = snapshot(f.app);
  f.env.FAULT_APP = f.app;
  executable(path.join(f.bin, 'mv'), `last="\${!#}"\nif [[ "$last" == "$FAULT_APP/docker/xcode-shims/bridge-client.mjs" ]]; then exit 73; fi\nexec /bin/mv "$@"`);
  const r = install(f); assert.notEqual(r.status, 0);
  assert.deepEqual(snapshot(f.app), before);
  assert.equal(fs.existsSync(path.join(f.app, 'scripts/platform')), false);
  assert.equal(fs.existsSync(path.join(f.app, 'docker/xcode-shims')), false);
});

test('AC11 every added required tool file is mandatory in the exact release archive', t => {
  const f = sandbox(t, 'tools-update-required');
  const added = ['scripts/lib-tools.sh', 'scripts/lib-build.sh', 'scripts/tools-catalog.tsv', 'docker/install-tools.sh', 'scripts/platform/macos/lib-xcode-bridge.sh', 'scripts/platform/macos/xcode-bridge.py', 'docker/xcode-shims/bridge-client.mjs', 'docker/xcode-shims/xcodebuild', 'docker/xcode-shims/xcrun', 'docker/xcode-shims/simctl'];
  const before = snapshot(f.app);
  for (const missing of added) {
    release(f, releaseEntries(f.app).filter(entry => !entry.name.endsWith('/' + missing)));
    const r = install(f); assert.notEqual(r.status, 0, missing);
    assert.deepEqual(snapshot(f.app), before, missing);
  }
});
