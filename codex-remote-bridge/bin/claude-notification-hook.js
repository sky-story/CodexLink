#!/usr/bin/env node
// Hooks must never emit stdout (Claude can interpret it as context/decisions).
// Collect locally, then dispatch outside the CLI's critical path.
const { spawn } = require('node:child_process');
const { resolveCodexRemoteStateDir } = require('../src/daemon-state');
const { recordClaudeHook } = require('../src/claude-notifications');
const { createBarkNotifications } = require('../src/bark-push');

async function readInput(stream) {
  const chunks = []; let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) throw new Error('Hook input too large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
async function main(args = process.argv.slice(2)) {
  const stateIndex = args.indexOf('--state-dir');
  const stateDir = stateIndex >= 0 ? args[stateIndex + 1] : resolveCodexRemoteStateDir();
  if (!stateDir) throw new Error('Missing state directory');
  if (args.includes('--drain')) {
    const notifier = createBarkNotifications({ stateDir, report: () => {} });
    try { await notifier.drain(); } finally { await notifier.close(); }
    return;
  }
  const result = recordClaudeHook(await readInput(process.stdin), { stateDir });
  if (['disabled', 'ignored'].includes(result.status) || args.includes('--collect-only')) return;
  // A new hook also drains any pending events left by an earlier worker crash.
  const worker = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', __filename, '--drain', '--state-dir', stateDir], {
    detached: true, stdio: 'ignore', windowsHide: true,
  });
  worker.on('error', () => {});
  worker.unref();
}
if (require.main === module) main().catch(() => {
  // Fail open for this *notification observer*. It must never approve, deny or
  // interrupt work. No raw exception: it may contain credentials or hook input.
  process.stderr.write('[CodexLink] Notification observer unavailable; CLI continues.\n');
  process.exitCode = 0;
});
module.exports = { main, readInput };
