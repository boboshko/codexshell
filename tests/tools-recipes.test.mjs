import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { sandbox, executable, bash } from './helpers/fixtures.mjs';

const packages = { PYTHON: ['python3', 'python3-pip', 'python3-venv'], GO: ['golang-go'], RUST: ['rustc', 'cargo'], JAVA: ['default-jdk'], MAKE: ['make'], CMAKE: ['cmake'], BUILD_ESSENTIAL: ['build-essential', 'clang'], GH_CLI: ['gh'], POSTGRES: ['postgresql-client'], MONGODB: ['mongodb-mongosh'], REDIS: ['redis-tools'], SSH_CLIENT: ['openssh-client'], RSYNC: ['rsync'], JQ: ['jq'], WGET: ['wget'], DOCKER_CLI: ['docker-ce-cli'], DOCKER_COMPOSE: ['docker-ce-cli', 'docker-compose-plugin'] };
function fixture(t) {
  const f = sandbox(t, 'tools-recipes');
  f.env.RECIPE_LOG = path.join(f.dir, 'recipe.log');
  let script = fs.readFileSync(path.join(f.app, 'docker/install-tools.sh'), 'utf8');
  // Redirect only container filesystem roots; recipe dispatch and argv remain unchanged.
  for (const dir of ['/etc/apt', '/usr/local/bin', '/var/lib/apt/lists']) {
    const target = path.join(f.dir, 'container', dir); fs.mkdirSync(target, { recursive: true });
    script = script.replaceAll(dir, target);
  }
  fs.mkdirSync(path.join(f.dir, 'container/etc/apt/sources.list.d'), { recursive: true });
  fs.writeFileSync(path.join(f.app, 'recipe-test.sh'), script);
  for (const name of ['apt-get', 'npm', 'curl', 'gpg', 'install', 'ln', 'unzip', 'tar']) executable(path.join(f.bin, name), `printf '%s %s\\n' '${name}' "$*" >> "$RECIPE_LOG"\n[[ "\${FAIL_RECIPE:-}" != '${name}' ]]`);
  executable(path.join(f.bin, 'sha256sum'), `printf 'checksum %s\\n' "$(cat)" >> "$RECIPE_LOG"\n[[ "\${FAIL_RECIPE:-}" != checksum ]]`);
  return { f, run: extra => bash(f, 'bash "$1/recipe-test.sh"', { TARGETARCH: 'arm64', ...extra }), log: () => fs.existsSync(f.env.RECIPE_LOG) ? fs.readFileSync(f.env.RECIPE_LOG, 'utf8') : '' };
}
for (const [slug, expected] of Object.entries(packages)) {
  test(`AC4 ${slug} executes only its client/tool package recipe`, t => {
    const { run, log } = fixture(t);
    const r = run({ [`TOOL_${slug}`]: '1' }); assert.equal(r.status, 0, r.stderr);
    for (const name of expected) assert.match(log(), new RegExp(`(?: |^)${name}(?: |$)`, 'm'));
    assert.doesNotMatch(log(), /postgresql-[0-9]|mongodb-org-server|redis-server|docker-ce(?: |$)/m);
    if (!['DOCKER_CLI', 'DOCKER_COMPOSE', 'MONGODB'].includes(slug)) assert.doesNotMatch(log(), /curl /);
    const failed = run({ [`TOOL_${slug}`]: '1', FAIL_RECIPE: 'apt-get' }); assert.notEqual(failed.status, 0);
  });
}
for (const arch of ['amd64', 'arm64']) for (const slug of ['BUN', 'UV', 'YQ']) {
  test(`AC4 ${slug} validates pinned ${arch} asset and propagates verification failure`, t => {
    const { run, log } = fixture(t);
    const extra = { TARGETARCH: arch, [`TOOL_${slug}`]: '1', ...(slug === 'UV' ? { TOOL_PYTHON: '1' } : {}) };
    const r = run(extra); assert.equal(r.status, 0, r.stderr);
    assert.match(log(), /curl .*--proto =https.*--connect-timeout 10.*--max-time 180/);
    assert.match(log(), /checksum [a-f0-9]{64} /);
    if (slug === 'BUN') assert.ok(log().includes(arch === 'amd64' ? 'bun-linux-x64-baseline' : 'bun-linux-aarch64'));
    if (slug === 'UV') { assert.ok(log().includes(arch === 'amd64' ? 'uv-x86_64' : 'uv-aarch64')); assert.match(log(), /\/uvx /); }
    if (slug === 'YQ') assert.ok(log().includes(`yq_linux_${arch}`));
    assert.notEqual(run({ ...extra, FAIL_RECIPE: 'checksum' }).status, 0);
    assert.notEqual(run({ ...extra, FAIL_RECIPE: 'curl' }).status, 0);
  });
}
test('AC4 pnpm installs pinned package, disabled branches do no network/package work and invalid data fails', t => {
  const { run, log } = fixture(t);
  assert.equal(run({}).status, 0); assert.equal(log(), '');
  assert.equal(run({ TOOL_PNPM: '1' }).status, 0); assert.match(log(), /npm install --global pnpm@[0-9]/);
  assert.notEqual(run({ TOOL_PNPM: '1', FAIL_RECIPE: 'npm' }).status, 0);
  for (const extra of [{ TOOL_JQ: 'on' }, { TOOL_JQ: '$(touch injected)' }, { TARGETARCH: 'riscv64' }, { TOOL_UV: '1' }]) assert.equal(run(extra).status, 2);
});
