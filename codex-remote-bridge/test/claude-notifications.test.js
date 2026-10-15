const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawn } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');
const { recordClaudeHook } = require('../src/claude-notifications');
const { NotificationStore } = require('../src/notification-store');
const { createBarkNotifications, eventNotice } = require('../src/bark-push');
const config = { enabled: true, reason: 'configured', endpoint: 'https://example.test/push', deviceKey: 'fixtureKeyOnly123', includeSessionLabel: true };
const hook = (event, fields = {}) => ({ hook_event_name: event, session_id: 'private-session', cwd: '/private/source/sample', ...fields });
const accepted = async () => ({ ok: true, status: 200, json: async () => ({ code: 200 }) });
function fixture(t) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-notification-test-'));
  fs.writeFileSync(path.join(stateDir, 'bark-config.json'), JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey, includeSessionLabel: true }), { mode: 0o600 });
  t.after(() => fs.rmSync(stateDir, { recursive: true, force: true }));
  return stateDir;
}
async function collect(stateDir, value) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', path.resolve(__dirname, '../bin/claude-notification-hook.js'), '--state-dir', stateDir, '--collect-only'], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', c => { stdout += c; }); child.stderr.on('data', c => { stderr += c; });
    child.on('error', reject); child.on('close', code => resolve({ code, stdout, stderr }));
    child.stdin.end(typeof value === 'string' ? value : JSON.stringify(value));
  });
}
async function drain(t, stateDir, sent, override = {}) {
  const notifier = createBarkNotifications({ stateDir, config, report: () => {}, fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); }, ...override });
  try { await notifier.drain(); } finally { await notifier.close(); }
}
test('Claude and Codex complete concurrently; providers/sessions remain distinct and payloads stay private', async t => {
  const stateDir = fixture(t), sent = [];
  for (const session_id of ['private-session', 'private-session-2']) {
    recordClaudeHook(hook('UserPromptSubmit', { session_id, prompt: 'PRIVATE PROMPT', session_title: 'same name' }), { stateDir });
    recordClaudeHook(hook('Stop', { session_id, last_assistant_message: 'PRIVATE ANSWER', background_tasks: [], session_crons: [] }), { stateDir });
  }
  const notifier = createBarkNotifications({ stateDir, config, report: () => {}, readThread: async id => ({ id, name: 'same name' }),
    fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  await notifier.handleOutbound({ method: 'turn/completed', params: { threadId: 'private-session', turn: { id: 'turn-1', status: 'completed' } } });
  await notifier.close();
  assert.equal(sent.length, 3); assert.equal(new Set(sent.map(p => p.group)).size, 3);
  assert.equal(sent.filter(p => p.title.startsWith('Claude')).length, 2);
  assert.equal(sent.filter(p => p.title.startsWith('Codex')).length, 1);
  assert(!JSON.stringify(sent).match(/PRIVATE|\/private|private-session/));
  const store = new NotificationStore(stateDir);
  const stored = JSON.stringify([store.db.prepare('SELECT * FROM notices').all(), store.db.prepare('SELECT * FROM claude_sessions').all()]);
  store.close();
  assert(!stored.match(/PRIVATE|\/private|private-session|fixtureKey/));
});
test('parallel hook processes and repeated drains send once; repeated same-text turns each notify', async t => {
  const stateDir = fixture(t), sent = [];
  assert.deepEqual(await collect(stateDir, hook('UserPromptSubmit', { prompt: 'same prompt' })), { code: 0, stdout: '', stderr: '' });
  const stops = await Promise.all(Array.from({ length: 6 }, () => collect(stateDir, hook('Stop', { last_assistant_message: 'same answer' }))));
  for (const result of stops) assert.deepEqual(result, { code: 0, stdout: '', stderr: '' });
  await Promise.all([drain(t, stateDir, sent), drain(t, stateDir, sent)]);
  assert.equal(sent.length, 1);
  await collect(stateDir, hook('UserPromptSubmit', { prompt: 'same prompt' }));
  await collect(stateDir, hook('Stop', { last_assistant_message: 'same answer' }));
  await drain(t, stateDir, sent);
  assert.equal(sent.length, 2);
  await drain(t, stateDir, sent); assert.equal(sent.length, 2);
});
test('queued turn identity and title are captured before the next turn starts', async t => {
  const stateDir = fixture(t), sent = [];
  recordClaudeHook(hook('UserPromptSubmit', { session_title: 'first name' }), { stateDir });
  recordClaudeHook(hook('Stop'), { stateDir });
  recordClaudeHook(hook('UserPromptSubmit', { session_title: 'second name' }), { stateDir });
  recordClaudeHook(hook('Stop'), { stateDir });
  await drain(t, stateDir, sent);
  assert.equal(sent.length, 2); assert.match(sent[0].body, /first name/); assert.match(sent[1].body, /second name/);
  assert.equal(sent[0].group, sent[1].group);
});
test('native prompt IDs deduplicate replayed starts and separate equal prompts across turns', async t => {
  const stateDir = fixture(t), sent = [];
  for (const prompt_id of ['native-1', 'native-1', 'native-2']) {
    recordClaudeHook(hook('UserPromptSubmit', { prompt_id, prompt: 'same text' }), { stateDir });
    recordClaudeHook(hook('Stop', { prompt_id }), { stateDir });
  }
  await drain(t, stateDir, sent); assert.equal(sent.length, 2);
});
test('background progress stays silent while responses, API errors, approvals and questions notify', async t => {
  const stateDir = fixture(t), sent = [];
  const record = input => recordClaudeHook(input, { stateDir });
  record(hook('UserPromptSubmit'));
  record(hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'PRIVATE COMMAND' } }));
  record(hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'PRIVATE COMMAND' } }));
  record(hook('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions: ['PRIVATE QUESTION'] } }));
  record(hook('PermissionRequest', { tool_name: 'AskUserQuestion', tool_input: { questions: ['PRIVATE QUESTION'] } }));
  record(hook('Stop', { background_tasks: [{ id: 'task', command: 'PRIVATE COMMAND' }], session_crons: [] }));
  record(hook('Stop', { background_tasks: [], session_crons: [] }));
  record(hook('StopFailure', { error: 'rate_limit', error_details: config.deviceKey }));
  await drain(t, stateDir, sent);
  assert.deepEqual(sent.map(p => p.title), ['Claude · 等待审批', 'Claude · 需要补充信息', 'Claude · 本轮已回复', 'Claude · API 错误']);
  assert(!JSON.stringify(sent).includes('PRIVATE')); assert(!sent.some(p => p.title.includes('任务已完成')));
});
test('background tasks and scheduled wakeups do not notify; the later idle response notifies once', async t => {
  const stateDir = fixture(t), sent = [];
  await collect(stateDir, hook('UserPromptSubmit'));
  for (const fields of [
    { background_tasks: [{ id: 'shell', status: 'running', command: 'PRIVATE COMMAND' }], session_crons: [] },
    { background_tasks: [], session_crons: [{ id: 'cron', recurring: true, prompt: 'PRIVATE PROMPT' }] },
    { session_crons: [{ id: 'wake-once', recurring: false }] },
  ]) {
    assert.deepEqual(await collect(stateDir, hook('Stop', fields)), { code: 0, stdout: '', stderr: '' });
    await drain(t, stateDir, sent);
    assert.equal(sent.length, 0);
  }
  await collect(stateDir, hook('Stop', { background_tasks: [], session_crons: [] }));
  await collect(stateDir, hook('Stop', { background_tasks: [], session_crons: [] }));
  await drain(t, stateDir, sent);
  assert.deepEqual(sent.map(p => p.title), ['Claude · 本轮已回复']);
});
test('upgrading the outbox silences legacy background writers without stopping their CLI sessions', async t => {
  const stateDir = fixture(t), sent = [];
  // Keep this old-style connection and prepared insert alive across the upgrade.
  const legacy = new DatabaseSync(path.join(stateDir, 'notification-deliveries.sqlite'));
  t.after(() => legacy.close());
  legacy.exec(`CREATE TABLE notices (provider TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
    status TEXT NOT NULL, created_at INTEGER NOT NULL, payload TEXT, PRIMARY KEY(provider,id));`);
  const insert = legacy.prepare('INSERT OR IGNORE INTO notices VALUES (?,?,?,?,?,?)');
  insert.run('claude', 'a'.repeat(64), 'background', 'pending', Date.now(), JSON.stringify({ title: 'old background', body: 'PRIVATE LABEL' }));
  insert.run('claude', 'b'.repeat(64), 'background', 'accepted', Date.now(), null);
  insert.run('claude', 'c'.repeat(64), 'background', 'unknown', Date.now(), null);
  const store = new NotificationStore(stateDir);
  store.close();
  assert.deepEqual({ ...legacy.prepare('SELECT status,payload FROM notices WHERE id=?').get('a'.repeat(64)) }, { status: 'suppressed', payload: null });
  assert.equal(legacy.prepare('SELECT status FROM notices WHERE id=?').get('b'.repeat(64)).status, 'accepted');
  assert.equal(legacy.prepare('SELECT status FROM notices WHERE id=?').get('c'.repeat(64)).status, 'unknown');
  assert.equal(insert.run('claude', 'd'.repeat(64), 'background', 'pending', Date.now(), '{}').changes, 0);
  insert.run('claude', 'e'.repeat(64), 'response_ready', 'pending', Date.now(), JSON.stringify({ title: 'Claude · 本轮已回复', body: 'response' }));
  insert.run('codex', 'f'.repeat(64), 'completed', 'pending', Date.now(), JSON.stringify({ title: 'Codex · 任务已完成', body: 'response' }));
  await drain(t, stateDir, sent);
  assert.deepEqual(sent.map(p => p.title), ['Claude · 本轮已回复', 'Codex · 任务已完成']);
});
test('subagent/tool events and disabled observer do not notify or create state', t => {
  const stateDir = fixture(t);
  for (const input of [null, {}, hook('PostToolUse'), hook('SubagentStop'), hook('Stop', { agent_id: 'child' }), hook('PreToolUse', { tool_name: 'Read' })]) {
    assert.equal(recordClaudeHook(input, { stateDir }).status, 'ignored');
  }
  assert.equal(recordClaudeHook(hook('Stop'), { stateDir, config: { enabled: false } }).status, 'disabled');
  assert(!fs.existsSync(path.join(stateDir, 'notification-deliveries.sqlite')));
});
test('labels stay opt-in; no preview leaks even without a title', async t => {
  const stateDir = fixture(t), sent = [], privateConfig = { ...config, includeSessionLabel: false };
  recordClaudeHook(hook('Stop', { session_title: 'PRIVATE NAME', last_assistant_message: 'PRIVATE ANSWER' }), { stateDir, config: privateConfig });
  await drain(t, stateDir, sent, { config: privateConfig });
  assert.equal(sent[0].title, 'Claude · 本轮已回复'); assert.match(sent[0].body, /Mac/); assert(!JSON.stringify(sent).includes('PRIVATE'));
});
test('a worker crash before dispatch retains pending work, but uncertain HTTP delivery is not resent', async t => {
  const stateDir = fixture(t), sent = [];
  await collect(stateDir, hook('Stop'));
  await drain(t, stateDir, sent, { fetchImpl: async () => { sent.push('attempt'); throw new Error('secret response'); } });
  await drain(t, stateDir, sent);
  assert.deepEqual(sent, ['attempt']);
  const store = new NotificationStore(stateDir);
  assert.equal(store.db.prepare('SELECT status FROM notices').get().status, 'unknown'); store.close();
});
test('disabling labels before queued dispatch removes the earlier label', async t => {
  const stateDir = fixture(t), sent = [];
  recordClaudeHook(hook('Stop', { session_title: 'NO LONGER SHARED' }), { stateDir });
  await drain(t, stateDir, sent, { config: { ...config, includeSessionLabel: false } });
  assert(!JSON.stringify(sent).includes('NO LONGER SHARED')); assert.equal(sent[0].group, 'Claude');
});
test('independent dispatcher processes claim each queued event exactly once', async t => {
  const stateDir = fixture(t);
  for (let i = 0; i < 6; i++) recordClaudeHook(hook('Stop', { session_id: `session-${i}` }), { stateDir });
  const source = `const {createBarkNotifications}=require(process.argv[1]);
    const n=createBarkNotifications({stateDir:process.argv[2],config:JSON.parse(process.argv[3]),report:()=>{},
      fetchImpl:async (_,o)=>{await new Promise(r=>setTimeout(r,15));process.stdout.write(o.body+'\\n');return {ok:true,status:200,json:async()=>({code:200})};}});
    n.drain().then(()=>n.close());`;
  const results = await Promise.all(Array.from({ length: 4 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', '-e', source, path.resolve(__dirname, '../src/bark-push.js'), stateDir, JSON.stringify(config)], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', c => { stdout += c; }); child.stderr.on('data', c => { stderr += c; });
    child.on('error', reject); child.on('close', code => {
      if (code !== 0 || stderr) return reject(new Error('Dispatcher process failed'));
      resolve(stdout.trim().split('\n').filter(Boolean).map(s => JSON.parse(s)));
    });
  })));
  const sent = results.flat(); assert.equal(sent.length, 6); assert.equal(new Set(sent.map(p => p.group)).size, 6);
});
test('legacy Codex ledger migrates without replay and malformed hook input is harmless', async t => {
  const stateDir = fixture(t), sent = [];
  // Hooks may create the shared database before the old Bridge has sent its
  // final notification. A later process must still import that receipt.
  const early = new NotificationStore(stateDir); early.close();
  const event = { method: 'turn/completed', params: { threadId: 'old', turn: { id: 'old-run', status: 'completed' } } };
  fs.writeFileSync(path.join(stateDir, 'bark-deliveries.json'), JSON.stringify({ [eventNotice(event).id]: { at: Date.now(), kind: 'completed', status: 'accepted' } }), { mode: 0o600 });
  const notifier = createBarkNotifications({ stateDir, config, report: () => {}, fetchImpl: async () => { sent.push('sent'); return accepted(); } });
  await notifier.handleOutbound(event); await notifier.close(); assert.equal(sent.length, 0);
  const result = await collect(stateDir, 'PRIVATE INVALID JSON');
  assert.equal(result.code, 0); assert.equal(result.stdout, ''); assert(!result.stderr.includes('PRIVATE'));
});
