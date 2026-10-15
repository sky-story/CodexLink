#!/usr/bin/env node
// Opt a normal interactive Claude terminal into the local CodexLink channel.
// Existing Claude account, project policies and tool permission mode are retained.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { installRuntime } = require('./service-runtime.cjs');
const { resolveCodexRemoteStateDir } = require('../codex-remote-bridge/src/daemon-state');
const { ClaudeChannelStore } = require('../codex-remote-bridge/src/claude-channel-store');
const quote = value => `'${String(value).replace(/'/g, `'"'"'`)}'`;

function prepareSession({ cwd = process.cwd(), name = path.basename(cwd), resume, stateDir = resolveCodexRemoteStateDir(), runtime = installRuntime() } = {}) {
  const id = resume || randomUUID(), generation = randomUUID();
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id)) throw new Error('Resume requires a full Claude session UUID');
  const store = new ClaudeChannelStore({ stateDir });
  try { store.register({ id, generation, cwd, name }); } finally { store.close(); }
  const folder = path.join(stateDir, 'claude-launches', generation);
  fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
  const common = ['--state-dir', stateDir, '--session-id', id, '--generation', generation];
  const channel = path.join(runtime.root, 'codex-remote-bridge/bin/claude-channel.js');
  const hook = path.join(runtime.root, 'codex-remote-bridge/bin/claude-session-hook.js');
  const hooks = {};
  const command = [process.execPath, '--disable-warning=ExperimentalWarning', hook, ...common].map(quote).join(' ');
  for (const event of ['UserPromptSubmit', 'Stop', 'StopFailure', 'PostToolUse', 'PostToolUseFailure', 'SessionEnd']) hooks[event] = [{ hooks: [{ type: 'command', command, timeout: 5 }] }];
  const mcpFile = path.join(folder, 'mcp.json'), settingsFile = path.join(folder, 'hooks.json');
  fs.writeFileSync(mcpFile, JSON.stringify({ mcpServers: { codexlink: { command: process.execPath, args: ['--disable-warning=ExperimentalWarning', channel, ...common] } } }), { mode: 0o600 });
  fs.writeFileSync(settingsFile, JSON.stringify({ hooks }), { mode: 0o600 });
  return { id, generation, folder, stateDir, args: [resume ? '--resume' : '--session-id', id, '--name', name, '--mcp-config', mcpFile,
    '--settings', settingsFile, '--dangerously-load-development-channels', 'server:codexlink'] };
}
async function main(args = process.argv.slice(2)) {
  if (args.includes('--help')) {
    console.log('Usage: clink [--name NAME] [--resume SESSION_UUID]\nOr: node scripts/claude-session.cjs [--name NAME] [--resume SESSION_UUID]\nRun in your working project. The session name defaults to the current folder name.\nClaude asks you to confirm this local development channel.'); return;
  }
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--name', '--resume'].includes(args[i]) || !args[i + 1]) throw new Error('Use --help for supported options');
    options[args[i].slice(2)] = args[i + 1];
  }
  if (!process.stdin.isTTY) throw new Error('Open this command in an interactive terminal; Claude development channels require local confirmation');
  const session = prepareSession(options);
  console.log('CodexLink: starting Claude in this terminal. Confirm the local development channel in Claude.');
  console.log('Messages and tool approvals will be available to your paired iPhone. Project trust and MCP consent stay on Mac.');
  try {
    const code = await new Promise((resolve, reject) => {
      const child = spawn('claude', session.args, { cwd: process.cwd(), env: process.env, stdio: 'inherit' });
      // The terminal delivers SIGINT to its foreground group, including Claude.
      // Keep the wrapper alive while Claude handles interruption in its own TUI.
      const onInterrupt = () => {}, onTerminate = () => child.kill('SIGTERM');
      process.on('SIGINT', onInterrupt); process.on('SIGTERM', onTerminate);
      const cleanup = () => { process.off('SIGINT', onInterrupt); process.off('SIGTERM', onTerminate); };
      child.on('error', e => { cleanup(); reject(e); });
      child.on('exit', value => { cleanup(); resolve(value || 0); });
    });
    process.exitCode = code;
  } finally {
    const store = new ClaudeChannelStore({ stateDir: session.stateDir });
    try { store.closeSession(session.id, session.generation); } finally { store.close(); }
    fs.rmSync(session.folder, { recursive: true, force: true });
  }
}
if (require.main === module) main().catch(() => { console.error('Unable to launch Claude channel. Check Claude installation, session ID, and interactive terminal.'); process.exitCode = 1; });
module.exports = { prepareSession };
