#!/usr/bin/env node
//
// Cross-platform launcher for scripts/verify.sh.
//
// On Windows, `bash` on PATH is usually WSL's stub (C:\Windows\System32\bash.exe).
// With no distro installed it fails with:
//   WSL (Relay) ERROR: CreateProcessCommon: execvpe(/bin/bash) failed
// which has nothing to do with the script. Git for Windows ships a real bash,
// so find that one instead of trusting PATH order.

const { spawnSync, execFileSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const path = require('node:path');

const script = path.join(__dirname, 'verify.sh');

function gitBash() {
  try {
    // .../Git/cmd/git.exe -> .../Git/bin/bash.exe
    const git = execFileSync('where', ['git'], { encoding: 'utf8' }).split(/\r?\n/)[0];
    const candidate = path.join(path.dirname(git), '..', 'bin', 'bash.exe');
    if (existsSync(candidate)) return candidate;
  } catch { /* git not on PATH */ }
  return null;
}

const candidates = process.platform === 'win32'
  ? [gitBash(), 'C:\\Program Files\\Git\\bin\\bash.exe', 'C:\\Program Files (x86)\\Git\\bin\\bash.exe']
  : ['/bin/bash', 'bash'];

const bash = candidates.find((c) => c && (c === 'bash' || existsSync(c)));

if (!bash) {
  console.error('No usable bash found. Install Git for Windows, or run the checks directly:');
  console.error('  bash scripts/verify.sh');
  process.exit(127);
}

const { status } = spawnSync(bash, [script, ...process.argv.slice(2)], { stdio: 'inherit' });
process.exit(status === null ? 1 : status);
