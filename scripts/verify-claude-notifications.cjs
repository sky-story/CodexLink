#!/usr/bin/env node
// Exercise the installed Claude binary against a loopback-only fixture API.
// Uses an isolated config/state directory and fake credentials; no real push.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { updateHooks, quote } = require('./claude-notifications.cjs');
const { NotificationStore } = require('../codex-remote-bridge/src/notification-store');
const { createBarkNotifications } = require('../codex-remote-bridge/src/bark-push');

async function verify() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codexlink-claude-cli-fixture-'));
  const project = path.join(root, 'project'), stateDir = path.join(root, 'state'), claudeConfig = path.join(root, 'claude');
  for (const dir of [project, stateDir, claudeConfig]) fs.mkdirSync(dir, { mode: 0o700 });
  const expected = 'CODEXLINK_HOOK_FIXTURE_OK';
  let requests = 0;
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      if (req.url.includes('count_tokens')) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ input_tokens: 10 })); return; }
      if (!req.url.startsWith('/v1/messages')) { res.setHeader('Content-Type', 'application/json'); res.end('{}'); return; }
      requests++;
      let input; try { input = JSON.parse(raw); } catch { res.writeHead(400); res.end(); return; }
      const message = { id: 'msg_fixture', type: 'message', role: 'assistant', model: input.model,
        content: [{ type: 'text', text: expected }], stop_reason: 'end_turn', stop_sequence: null,
        usage: { input_tokens: 10, output_tokens: 8 } };
      if (!input.stream) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(message)); return; }
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      const event = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
      event('message_start', { message: { ...message, content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } });
      event('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: expected } });
      event('content_block_stop', { index: 0 });
      event('message_delta', { delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 8 } });
      event('message_stop', {}); res.end();
    });
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    fs.writeFileSync(path.join(stateDir, 'bark-config.json'), JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: 'fixtureKeyOnly123' }), { mode: 0o600 });
    const command = [process.execPath, '--disable-warning=ExperimentalWarning', path.resolve(__dirname, '../codex-remote-bridge/bin/claude-notification-hook.js'), '--state-dir', stateDir, '--collect-only'].map(quote).join(' ');
    const settingsFile = path.join(root, 'hooks.json');
    fs.writeFileSync(settingsFile, JSON.stringify(updateHooks({}, { command })), { mode: 0o600 });
    // Do not inherit provider tokens, model overrides, plugins, or proxy settings.
    const env = {};
    for (const key of ['PATH', 'HOME', 'TMPDIR', 'LANG', 'TERM']) if (process.env[key]) env[key] = process.env[key];
    Object.assign(env, { CLAUDE_CONFIG_DIR: claudeConfig, ANTHROPIC_API_KEY: 'fixture-key-not-real',
      ANTHROPIC_BASE_URL: `http://127.0.0.1:${server.address().port}`, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      DISABLE_AUTOUPDATER: '1', DISABLE_TELEMETRY: '1', NO_PROXY: '127.0.0.1,localhost' });
    const result = await new Promise((resolve, reject) => {
      const child = spawn('claude', ['-p', `Reply with ${expected}. Do not use tools.`, '--model', 'claude-sonnet-4-6',
        '--tools', '', '--max-turns', '1', '--output-format', 'json', '--no-session-persistence', '--setting-sources', '', '--settings', settingsFile],
      { cwd: project, env, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '', stderrBytes = 0, timedOut = false;
      child.stdout.on('data', c => { output += c; }); child.stderr.on('data', c => { stderrBytes += c.length; });
      const timeout = setTimeout(() => { timedOut = true; child.kill('SIGTERM'); }, 45000);
      child.on('error', error => { clearTimeout(timeout); reject(error); });
      child.on('close', code => {
        clearTimeout(timeout); let parsed; try { parsed = JSON.parse(output); } catch {}
        resolve({ exitCode: code, timedOut, responseMatches: parsed?.result?.trim() === expected, isError: parsed?.is_error, stderrBytes });
      });
    });
    const store = new NotificationStore(stateDir);
    const notices = store.db.prepare('SELECT provider,kind,status FROM notices').all(); store.close();
    let sent = 0;
    const notifier = createBarkNotifications({ stateDir, report: () => {}, fetchImpl: async () => { sent++; return { ok: true, status: 200, json: async () => ({ code: 200 }) }; } });
    await notifier.drain(); await notifier.close();
    const passed = result.exitCode === 0 && result.responseMatches && !result.isError && requests > 0
      && notices.length === 1 && notices[0].provider === 'claude' && notices[0].kind === 'response_ready' && sent === 1;
    console.log(JSON.stringify({ fixtureApi: true, realProvider: false, physicalPush: false, ...result, requests, notices, sends: sent, passed }, null, 2));
    return passed;
  } finally {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
}
if (require.main === module) verify().then(passed => { process.exitCode = passed ? 0 : 1; }).catch(() => { console.error('Isolated Claude CLI verification failed; no credentials or CLI output printed.'); process.exitCode = 1; });
module.exports = { verify };
