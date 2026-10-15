#!/usr/bin/env node
const { readInput } = require('./claude-notification-hook');
const { ClaudeChannelStore } = require('../src/claude-channel-store');
async function main() {
  const args = process.argv.slice(2), arg = key => args[args.indexOf(key) + 1];
  const input = await readInput(process.stdin);
  const store = new ClaudeChannelStore({ stateDir: arg('--state-dir') });
  try { store.hook(arg('--session-id'), arg('--generation'), input); } finally { store.close(); }
}
main().catch(() => { process.stderr.write('[CodexLink] Session observer unavailable; CLI continues.\n'); });
