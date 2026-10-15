#!/usr/bin/env node
// Interactive acceptance against the real Claude binary. Default: loopback API;
// --live: use the normal configured account/provider and its usage allowance.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { prepareSession } = require('./claude-session.cjs');
const { ClaudeChannelStore } = require('../codex-remote-bridge/src/claude-channel-store');

function isFixtureReply(permission, commandId, answer) {
  if (permission.status !== 'pending' || permission.tool !== 'mcp__codexlink__reply') return false;
  try {
    const input = JSON.parse(permission.preview);
    return input.message_id === commandId && input.text === answer
      && Object.keys(input).length === 2;
  } catch { return false; }
}

async function verify({ live = false } = {}) {
  if (!process.stdin.isTTY) throw new Error('Interactive terminal required for Claude’s development-channel confirmation');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codexlink-channel-cli-'));
  const project = path.join(root, 'project'), stateDir = path.join(root, 'state'), configDir = path.join(root, 'claude');
  for (const dir of [project, stateDir, configDir]) fs.mkdirSync(dir, { mode: 0o700 });
  const session = prepareSession({ cwd: project, stateDir, name: 'CodexLink isolated channel test', runtime: { root: path.resolve(__dirname, '..') } });
  const store = new ClaudeChannelStore({ stateDir });
  const commandId = randomUUID(), answer = 'CODEXLINK_CHANNEL_FIXTURE_OK';
  let child, timer, deadline, requests = 0, queued = false, permissionRelayed = false, done = false;
  const server = http.createServer((req, res) => {
    let raw = ''; req.on('data', c => { raw += c; });
    req.on('end', () => {
      if (req.url.includes('count_tokens')) { res.setHeader('Content-Type', 'application/json'); res.end('{"input_tokens":10}'); return; }
      if (!req.url.startsWith('/v1/messages')) { res.setHeader('Content-Type', 'application/json'); res.end('{}'); return; }
      let input; try { input = JSON.parse(raw); } catch { res.writeHead(400); res.end(); return; }
      requests++;
      const reply = (input.tools || []).find(tool => tool.name.endsWith('codexlink__reply'));
      const hasResult = (input.messages || []).some(message => Array.isArray(message.content) && message.content.some(block => block.type === 'tool_result' && block.tool_use_id === 'tool_fixture_reply'));
      const content = reply && !hasResult
        ? [{ type: 'tool_use', id: 'tool_fixture_reply', name: reply.name, input: { message_id: commandId, text: answer } }]
        : [{ type: 'text', text: 'Fixture response finished.' }];
      const stop = content[0].type === 'tool_use' ? 'tool_use' : 'end_turn';
      const message = { id: `msg_fixture_${requests}`, type: 'message', role: 'assistant', model: input.model, content,
        stop_reason: stop, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 20 } };
      if (!input.stream) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(message)); return; }
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      const event = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
      event('message_start', { message: { ...message, content: [], stop_reason: null } });
      if (stop === 'tool_use') {
        event('content_block_start', { index: 0, content_block: { ...content[0], input: {} } });
        event('content_block_delta', { index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(content[0].input) } });
      } else {
        event('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
        event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: content[0].text } });
      }
      event('content_block_stop', { index: 0 });
      event('message_delta', { delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 20 } });
      event('message_stop', {}); res.end();
    });
  });
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const env = live ? { ...process.env } : {};
    if (!live) {
      for (const key of ['PATH', 'HOME', 'TMPDIR', 'LANG', 'TERM']) if (process.env[key]) env[key] = process.env[key];
      Object.assign(env, { CLAUDE_CONFIG_DIR: configDir, ANTHROPIC_API_KEY: 'fixture-key-not-real',
        ANTHROPIC_BASE_URL: `http://127.0.0.1:${server.address().port}`, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
        DISABLE_AUTOUPDATER: '1', DISABLE_TELEMETRY: '1', NO_PROXY: 'localhost,127.0.0.1' });
    }
    console.log('Temporary test: accept Claude’s local development-channel prompt. Only the fixture-marker reply tool is approved automatically.');
    console.log(live ? 'Uses your normal account and may trigger your existing notification hooks.' : 'Fixture mode may be unavailable because Claude does not enable Channels for this isolated API configuration. Use --live from your normal authenticated terminal.');
    child = spawn('claude', [...session.args, '--strict-mcp-config', '--permission-mode', 'manual', '--tools', '',
      ...(!live ? ['--setting-sources', '', '--model', 'claude-sonnet-4-6'] : [])],
      { cwd: project, env, stdio: 'inherit' });
    const finished = new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); });
    timer = setInterval(() => {
      try {
        const snapshot = store.snapshot(session.id);
        if (!queued && snapshot.session.online) {
          store.submit({ sessionId: session.id, generation: session.generation, commandId, action: 'message', message: `Reply through the CodexLink reply tool with exactly ${answer}. Do not use other tools.` }); queued = true;
        }
        for (const permission of snapshot.permissions) {
          if (!isFixtureReply(permission, commandId, answer)) continue;
          store.submit({ sessionId: session.id, generation: session.generation, commandId: `approve-${permission.id}`, action: 'permission', permissionId: permission.id, behavior: 'allow' });
          permissionRelayed = true;
        }
        if (!done && store.command(commandId, session.id)?.status === 'replied') {
          done = true; setTimeout(() => child.kill('SIGTERM'), 1500);
        }
      } catch { /* Setup can still be in progress. No user state is involved. */ }
    }, 200);
    deadline = setTimeout(() => child.kill('SIGTERM'), 150000);
    await finished;
    const exactReply = store.snapshot(session.id).messages.some(message => message.id === `reply-${commandId}` && message.text === answer);
    const passed = done && exactReply && permissionRelayed;
    console.log('\n' + JSON.stringify({ realCLI: true, fixtureAPI: !live, liveProvider: live, physicalPhone: false, queued, requests, permissionRelayed, replied: done, passed }, null, 2));
    return passed;
  } finally {
    clearInterval(timer); clearTimeout(deadline); if (child && child.exitCode === null) child.kill('SIGTERM');
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    store.close(); fs.rmSync(root, { recursive: true, force: true });
  }
}
if (require.main === module) verify({ live: process.argv.includes('--live') }).then(passed => { process.exitCode = passed ? 0 : 1; }).catch(e => { console.error(e.message); process.exitCode = 1; });
module.exports = { verify, isFixtureReply };
