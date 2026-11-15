#!/usr/bin/env node
// Single-writer state transitions. Run from the target project root.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const statePath = '.pipeline/state.json';
const [command, ...args] = process.argv.slice(2);
const help = `Usage: node scripts/pipeline-state.mjs <command>
  init <task>                  Create state; never overwrite an existing run
  status                       Print current state
  platforms <name...>           Set target platforms during analysis/build
  start                        Start the current stage
  criteria <json-file>          Register/update acceptance criteria
  pass                         Pass current stage after checking its report
  block <reason>               Block current stage
  retry <stage 1..8> <reason>   Invalidate this and all later stages
Criteria: [{"id":"AC-1","description":"...","verified":false,"evidence":""}]
Only the orchestrator may write state. Do not run concurrent orchestrators.`;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function save(state) {
  const temp = `${statePath}.${randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { flag: 'wx' });
    fs.renameSync(temp, statePath);
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}
function event(state, action, stage, reason = '') {
  state.history.push({ at: new Date().toISOString(), action, stage, reason });
}
function criteriaValid(criteria) {
  return Array.isArray(criteria) && criteria.length > 0 &&
    new Set(criteria.map(c => c.id)).size === criteria.length &&
    criteria.every(c => /^AC-[1-9][0-9]*$/.test(c.id) &&
      typeof c.description === 'string' && c.description.trim() &&
      typeof c.verified === 'boolean' && typeof c.evidence === 'string' &&
      (!c.verified || c.evidence.trim()));
}
function run() {
  if (!command || command === '--help') { console.log(help); return; }
  if (command === 'init') {
    assert(args.join(' ').trim(), 'Task is required');
    assert(!fs.existsSync(statePath), 'Existing run: use status and resume');
    const state = JSON.parse(fs.readFileSync('.pipeline/templates/state.json', 'utf8'));
    state.task = args.join(' ');
    event(state, 'init', 1);
    // Exclusive create protects an existing run even if another init races.
    fs.writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, { flag: 'wx' });
    return;
  }
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  assert(state.stages?.length === 8 && state.stages.every((s, i) => s.id === i + 1),
    'Expected eight ordered stages');
  assert(Number.isInteger(state.current_stage) && state.current_stage >= 1 &&
    state.current_stage <= 8, 'Invalid current_stage');
  if (command === 'status') { console.log(JSON.stringify(state, null, 2)); return; }
  const current = state.stages[state.current_stage - 1];
  if (command === 'retry') {
    const target = Number(args[0]);
    const reason = args.slice(1).join(' ').trim();
    assert(Number.isInteger(target) && target >= 1 && target <= state.current_stage,
      'Retry must target a current or previous stage');
    assert(reason, 'Retry reason is required');
    for (const stage of state.stages.slice(target - 1)) {
      stage.status = 'pending';
      stage.blocking_issues = [];
    }
    state.stages[target - 1].iterations += 1;
    state.current_stage = target;
    // Documentation/review-only retries retain test evidence. Code changes must
    // retry build, which invalidates tests as well as all later gates.
    for (const ac of target <= 5 ? state.acceptance_criteria : []) {
      if (typeof ac === 'object' && ac !== null) { ac.verified = false; ac.evidence = ''; }
    }
    event(state, 'retry', target, reason);
  } else if (command === 'platforms') {
    assert([1, 4].includes(current.id) && current.status === 'in_progress',
      'Platforms can only be set during analysis or build');
    assert(args.length > 0 && new Set(args).size === args.length &&
      args.every(platform => ['linux', 'macos', 'windows'].includes(platform)),
      'Provide distinct platforms: linux, macos, windows');
    state.target_platforms = args;
    event(state, 'platforms', current.id, args.join(' '));
  } else if (command === 'criteria') {
    assert([1, 5].includes(current.id) && current.status === 'in_progress',
      'Criteria can only be written during analysis or testing');
    assert(args.length === 1, 'Provide a criteria JSON file');
    const criteria = JSON.parse(fs.readFileSync(args[0], 'utf8'));
    assert(criteriaValid(criteria), 'Invalid or empty acceptance criteria');
    if (current.id === 1) {
      assert(criteria.every(c => !c.verified), 'Analysis cannot verify acceptance tests');
    } else {
      assert(criteria.length === state.acceptance_criteria.length && criteria.every(c =>
        state.acceptance_criteria.some(old => old.id === c.id && old.description === c.description)),
      'Testing cannot remove or redefine requirements; retry analysis');
    }
    state.acceptance_criteria = criteria;
    event(state, 'criteria', current.id);
  } else {
    assert(['start', 'pass', 'block'].includes(command), `Unknown command: ${command}`);
    assert(state.stages.slice(0, current.id - 1).every(s =>
      s.status === 'passed' && s.blocking_issues.length === 0), 'Previous gates have not passed');
    if (command === 'start') {
      assert(['pending', 'in_progress'].includes(current.status), 'Use retry before restarting');
      assert(current.blocking_issues.length === 0, 'Unresolved blocking issues');
      current.status = 'in_progress';
    } else if (command === 'block') {
      assert(current.status === 'in_progress', 'Start the stage first');
      assert(args.join(' ').trim(), 'Blocking reason is required');
      current.status = 'blocked';
      current.blocking_issues = [args.join(' ')];
    } else {
      assert(current.status === 'in_progress', 'Stage must be in_progress');
      assert(current.blocking_issues.length === 0, 'Unresolved blocking issues');
      const artifact = path.resolve(current.artifact);
      assert(artifact.startsWith(`${path.resolve('.pipeline')}${path.sep}`), 'Artifact outside .pipeline');
      const report = fs.readFileSync(artifact, 'utf8');
      assert(/^# .+/m.test(report) && /^\*\*PASS\*\*\s*$/m.test(report) &&
        !/^\*\*BLOCK\*\*\s*$/m.test(report), 'Report must contain a heading and an unambiguous PASS gate');
      assert(criteriaValid(state.acceptance_criteria), 'Register acceptance criteria first');
      if ([5, 8].includes(current.id)) {
        assert(state.acceptance_criteria.every(c => c.verified && c.evidence.trim()),
          'All acceptance criteria require actual verification evidence');
      }
      if (current.id === 8) {
        assert(fs.readFileSync('.pipeline/08-release/CHANGELOG.md', 'utf8').trim(), 'CHANGELOG is empty');
      }
      current.status = 'passed';
      state.current_stage = Math.min(8, current.id + 1);
    }
    event(state, command, current.id, args.join(' '));
  }
  save(state);
}

try { run(); } catch (error) {
  console.error(`pipeline-state: ${error.message}`);
  process.exitCode = 1;
}
