#!/usr/bin/env node
const { createClaudeChannel } = require('../src/claude-channel');
const { ClaudeChannelStore } = require('../src/claude-channel-store');
const args = process.argv.slice(2);
const arg = key => args[args.indexOf(key) + 1];
try {
  const channel = createClaudeChannel({ sessionId: arg('--session-id'), generation: arg('--generation'), store: new ClaudeChannelStore({ stateDir: arg('--state-dir') }) });
  channel.start().catch(() => { process.stderr.write('[CodexLink] Claude channel unavailable.\n'); process.exitCode = 1; });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => channel.close().finally(() => process.exit(0)));
} catch { process.stderr.write('[CodexLink] Claude channel unavailable.\n'); process.exitCode = 1; }
