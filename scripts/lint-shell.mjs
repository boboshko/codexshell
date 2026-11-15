#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const strict = args[0] === '--strict';
if (strict) args.shift();
if (!args.length || args[0] === '--help') {
  console.log('Usage: node scripts/lint-shell.mjs [--strict] <file...>\nExit: 0 clean/SKIP, 1 lint/error, 2 usage, 3 missing tool in strict mode.');
  process.exitCode = args[0] === '--help' ? 0 : 2;
} else {
  let failed = false;
  let missing = false;
  for (const file of args) {
    const full = path.resolve(file);
    if (!fs.existsSync(full) || !fs.statSync(full).isFile()) {
      console.error(`ERROR: not a file: ${file}`); failed = true; continue;
    }
    const ext = path.extname(full).toLowerCase();
    let tool, toolArgs;
    if (['.sh', '.bash'].includes(ext)) {
      tool = 'shellcheck'; toolArgs = ['-x', '--severity=warning', '--', full];
    } else if (['.ps1', '.psm1'].includes(ext)) {
      tool = 'pwsh'; toolArgs = ['-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        fileURLToPath(new URL('./lint-powershell.ps1', import.meta.url)), full];
    } else {
      console.error(`ERROR: unsupported shell file: ${file}`); failed = true; continue;
    }
    // No shell and no interpolated PowerShell command text: file names remain data.
    const result = spawnSync(tool, toolArgs, { encoding: 'utf8', shell: false });
    if (result.error?.code === 'ENOENT' || result.status === 3) {
      console.error(`SKIP: ${tool}/analyzer unavailable: ${file}`); missing = true;
    } else if (result.error || result.status !== 0) {
      console.error(`FAIL: ${file}\n${result.stderr || result.stdout || result.error || result.signal}`);
      failed = true;
    } else console.log(`PASS: ${file}`);
  }
  process.exitCode = failed ? 1 : (strict && missing ? 3 : 0);
}
