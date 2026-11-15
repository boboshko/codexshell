import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codexshell-state-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, '.pipeline/templates'), { recursive: true });
  fs.copyFileSync(path.join(root, '.pipeline/templates/state.json'), path.join(dir, '.pipeline/templates/state.json'));
  const run = (...args) => spawnSync(process.execPath, [path.join(root, 'scripts/pipeline-state.mjs'), ...args], { cwd: dir, encoding: 'utf8' });
  const read = () => JSON.parse(fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8'));
  assert.equal(run('init', 'CodexShell checkpoint test').status, 0);
  return { dir, run, read };
}

test('platform checkpoint survives status without changing stage or criteria', t => {
  const { dir, run, read } = fixture(t);
  assert.equal(run('start').status, 0);
  const criteria = [{ id: 'AC-1', description: 'Persist checkpoint', verified: false, evidence: '' }];
  fs.writeFileSync(path.join(dir, 'criteria.json'), JSON.stringify(criteria));
  assert.equal(run('criteria', 'criteria.json').status, 0);
  const before = read();
  assert.equal(run('platforms', 'macos', 'linux').status, 0);
  const after = read();
  assert.deepEqual(after.target_platforms, ['macos', 'linux']);
  assert.deepEqual(after.stages, before.stages);
  assert.deepEqual(after.acceptance_criteria, before.acceptance_criteria);
  assert.equal(after.history.at(-1).action, 'platforms');
  const bytes = fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8');
  assert.deepEqual(JSON.parse(run('status').stdout), after);
  assert.equal(fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8'), bytes);
  assert.equal(run('init', 'Overwrite existing task').status, 1);
  assert.equal(fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8'), bytes);
});

test('invalid platform input never corrupts a checkpoint', t => {
  const { dir, run } = fixture(t);
  assert.equal(run('platforms', 'linux').status, 1);
  assert.equal(run('start').status, 0);
  const saved = fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8');
  for (const names of [[], ['linux', 'linux'], ['linux', 'unknown'], ['$(touch bad)']]) {
    assert.equal(run('platforms', ...names).status, 1);
    assert.equal(fs.readFileSync(path.join(dir, '.pipeline/state.json'), 'utf8'), saved);
  }
  assert.equal(fs.existsSync(path.join(dir, 'bad')), false);
});

test('platform changes are allowed in build and require a retry after testing begins', t => {
  const { dir, run, read } = fixture(t);
  assert.equal(run('start').status, 0);
  fs.writeFileSync(path.join(dir, 'criteria.json'), JSON.stringify([{ id: 'AC-1', description: 'Checkpoint', verified: false, evidence: '' }]));
  assert.equal(run('criteria', 'criteria.json').status, 0);
  for (let stage = 1; stage <= 4; stage++) {
    if (stage > 1) assert.equal(run('start').status, 0);
    if (stage === 4) assert.equal(run('platforms', 'macos', 'linux').status, 0);
    const artifact = path.join(dir, read().stages[stage - 1].artifact);
    fs.mkdirSync(path.dirname(artifact), { recursive: true });
    fs.writeFileSync(artifact, '# Checkpoint\n\n**PASS**\n');
    assert.equal(run('pass').status, 0);
  }
  assert.equal(run('start').status, 0);
  assert.equal(run('platforms', 'windows').status, 1);
  assert.deepEqual(read().target_platforms, ['macos', 'linux']);
  assert.equal(run('retry', '4', 'Change platform scope').status, 0);
  assert.equal(run('start').status, 0);
  assert.equal(run('platforms', 'linux').status, 0);
});
