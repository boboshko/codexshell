#!/usr/bin/env node
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const MAX_RESPONSE = 12 * 1024 * 1024;
const MAX_OUTPUT = 8 * 1024 * 1024;

function fail(message) {
  process.stderr.write(`Xcode: ${message}\n`);
  process.exitCode = 1;
}

function privateFile(directory, name) {
  const filename = path.join(directory, name);
  const stat = fs.lstatSync(filename);
  if (!stat.isFile() || (stat.mode & 0o077) !== 0) throw new Error('invalid session file');
  return fs.readFileSync(filename, 'utf8');
}

function decode(value) {
  if (typeof value !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    throw new Error('invalid bridge response');
  }
  return Buffer.from(value, 'base64');
}

try {
  const command = process.argv[2];
  const args = process.argv.slice(3);
  const health = command === '--health' && args.length === 0;
  if (!health && !['xcodebuild', 'xcrun', 'simctl'].includes(command)) throw new Error('unsupported command');
  if (process.env.CODEXSHELL_XCODE !== '1') throw new Error('bridge is disabled');
  const host = process.env.CODEXSHELL_XCODE_HOST;
  const port = Number(process.env.CODEXSHELL_XCODE_PORT);
  if (!host || !/^(?:host\.docker\.internal|(?:\d{1,3}\.){3}\d{1,3}|localhost)$/.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('invalid bridge endpoint');
  }
  if (args.length > 256 || args.some(value => Buffer.byteLength(value) > 8192 || value.includes('\0'))) throw new Error('argument limit exceeded');
  const directory = process.env.CODEXSHELL_XCODE_SESSION_DIR || '/run/codexshell-xcode';
  const token = privateFile(directory, 'token').trim();
  if (!/^[0-9a-f]{64}$/.test(token)) throw new Error('invalid session token');
  const manifest = JSON.parse(privateFile(directory, 'manifest.json'));
  if (manifest.version !== 1 || manifest.port !== port || typeof manifest.instance !== 'string' || !/^[0-9a-f]{32}$/.test(manifest.instance)) throw new Error('session endpoint mismatch');
  const body = health ? '' : JSON.stringify({ version: 1, command, args, cwd: process.cwd() });
  if (Buffer.byteLength(body) > 1024 * 1024) throw new Error('request limit exceeded');
  const timer = setTimeout(() => request.destroy(new Error('request timed out')), health ? 5000 : 125000);
  const request = http.request({ host, port, path: health ? '/health' : '/run', method: health ? 'GET' : 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, response => {
    const chunks = [];
    let size = 0;
    response.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_RESPONSE) request.destroy(new Error('response limit exceeded'));
      else chunks.push(chunk);
    });
    response.on('error', () => { clearTimeout(timer); fail('bridge response failed.'); });
    response.on('end', () => {
      clearTimeout(timer);
      try {
        if (response.statusCode !== 200) throw new Error('bridge rejected request');
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (health) {
          if (value.version !== 1 || value.instance !== manifest.instance) throw new Error('bridge identity mismatch');
          process.exitCode = 0;
          return;
        }
        if (value.version !== 1 || !Number.isInteger(value.exit_code) || value.exit_code < 0 || value.exit_code > 255) throw new Error('invalid bridge response');
        const stdout = decode(value.stdout);
        const stderr = decode(value.stderr);
        if (stdout.length + stderr.length > MAX_OUTPUT) throw new Error('output limit exceeded');
        process.stdout.write(stdout);
        process.stderr.write(stderr);
        process.exitCode = value.exit_code;
      } catch {
        fail('bridge rejected request or returned an invalid response.');
      }
    });
  });
  request.on('error', () => { clearTimeout(timer); fail('bridge request failed.'); });
  request.end(body);
} catch {
  fail('bridge is unavailable or request configuration is invalid.');
}
