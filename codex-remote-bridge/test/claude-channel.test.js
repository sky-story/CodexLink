const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { randomUUID } = require('node:crypto');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');
const { z } = require('zod');
const { ClaudeChannelStore, LEASE_MS, APPROVAL_MS } = require('../src/claude-channel-store');
const { createClaudeChannelRouter } = require('../src/claude-channel-router');
const { prepareSession } = require('../../scripts/claude-session.cjs');
const { isFixtureReply } = require('../../scripts/verify-claude-channel.cjs');
function fixture(t) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-channel-test-'));
  let now = Date.now();
  const store = new ClaudeChannelStore({ stateDir, now: () => now });
  t.after(() => { store.close(); fs.rmSync(stateDir, { recursive: true, force: true }); });
  const id = randomUUID(), generation = randomUUID();
  store.register({ id, generation, cwd: '/fixture/project', name: 'Project' }); store.heartbeat(id, generation);
  return { stateDir, store, id, generation, advance: ms => { now += ms; }, message: (commandId = randomUUID(), message = 'hello') => ({ sessionId: id, generation, commandId, action: 'message', message }) };
}
const approval = { request_id: 'abcde', tool_name: 'Bash', description: 'Write the result file', input_preview: '{"command":"printf result > result.txt"}' };

test('phone messages persist; replies belong to the exact original session and command', t => {
  const f = fixture(t), command = f.message();
  assert.equal(f.store.submit(command).status, 'queued');
  assert.equal(f.store.submit(command).status, 'queued');
  const claimed = f.store.claim(f.id, f.generation);
  assert.equal(claimed.id, command.commandId);
  assert.equal(f.store.command(command.commandId, f.id).status, 'unknown');
  assert.equal(f.store.claim(f.id, f.generation), null);
  f.store.finish(command.commandId, 'sent');
  f.store.reply(f.id, f.generation, command.commandId, 'answer');
  f.store.reply(f.id, f.generation, command.commandId, 'answer');
  f.store.finish(command.commandId, 'sent');
  const snap = f.store.snapshot(f.id);
  assert.equal(snap.session.verified, true); assert.equal(snap.messages.length, 2);
  assert.equal(snap.receipts[0].status, 'replied');
  assert.throws(() => f.store.submit({ ...command, message: 'different' }), /reused/);
  assert.throws(() => f.store.reply(f.id, f.generation, command.commandId, 'different'), /already exists/);
  assert.throws(() => f.store.reply(f.id, f.generation, 'nonexistent', 'answer'), /does not match/);
});
test('offline, stale generations and unsupported actions never enqueue work', t => {
  const f = fixture(t);
  assert.throws(() => f.store.submit({ ...f.message(), generation: 'wrong' }), /changed/);
  assert.throws(() => f.store.submit({ ...f.message(), action: 'interrupt' }), /Unsupported/);
  f.advance(LEASE_MS + 1);
  assert.throws(() => f.store.submit(f.message()), /offline/);
  assert.equal(f.store.snapshot(f.id).receipts.length, 0);
});
test('parallel senders cannot claim a command twice and restart never replays unknown writes', t => {
  const f = fixture(t); f.store.submit(f.message());
  const second = new ClaudeChannelStore({ stateDir: f.stateDir });
  try {
    assert(f.store.claim(f.id, f.generation)); assert.equal(second.claim(f.id, f.generation), null);
    f.advance(LEASE_MS + 1);
    f.store.register({ id: f.id, generation: 'reopened', cwd: '/fixture/project', name: 'Project' });
    f.store.heartbeat(f.id, 'reopened');
    assert.equal(f.store.claim(f.id, 'reopened'), null);
    assert.equal(f.store.snapshot(f.id).receipts[0].status, 'unknown');
  } finally { second.close(); }
});
test('permission verdicts require a live request, one decision, matching session and generation', t => {
  const f = fixture(t), permissionId = f.store.permission(f.id, f.generation, approval);
  const decision = { sessionId: f.id, generation: f.generation, commandId: randomUUID(), action: 'permission', permissionId, behavior: 'allow' };
  assert.equal(f.store.submit(decision).status, 'queued');
  assert.equal(f.store.submit(decision).status, 'queued');
  assert.throws(() => f.store.submit({ ...decision, commandId: randomUUID(), behavior: 'deny' }), /already answered/);
  assert.throws(() => f.store.submit({ ...decision, behavior: 'alwaysAllow' }), /Only allow/);
  const command = f.store.claim(f.id, f.generation);
  assert.equal(command.payload.relayId, 'abcde'); assert.equal(command.payload.behavior, 'allow');
  f.store.finish(command.id, 'sent');
  assert.equal(f.store.snapshot(f.id).permissions[0].status, 'submitted');
  f.store.hook(f.id, f.generation, { hook_event_name: 'PostToolUse', session_id: f.id });
  assert.deepEqual(f.store.snapshot(f.id).permissions, []);
  assert.equal(f.store.command(command.id, f.id).status, 'sent', 'no invented approval acknowledgment');
});
test('expired or locally resolved approvals cannot be dispatched; ambiguous IDs fail closed', t => {
  const f = fixture(t), permissionId = f.store.permission(f.id, f.generation, approval);
  f.store.submit({ sessionId: f.id, generation: f.generation, commandId: randomUUID(), action: 'permission', permissionId, behavior: 'allow' });
  f.store.hook(f.id, f.generation, { hook_event_name: 'PostToolUse', session_id: f.id });
  assert.equal(f.store.claim(f.id, f.generation).skipped, true);
  const second = f.store.permission(f.id, f.generation, { ...approval, request_id: 'bcdef' });
  f.advance(APPROVAL_MS + 1); f.store.heartbeat(f.id, f.generation);
  assert.throws(() => f.store.submit({ sessionId: f.id, generation: f.generation, commandId: randomUUID(), action: 'permission', permissionId: second, behavior: 'allow' }), /expired/);
  f.store.permission(f.id, f.generation, approval);
  assert.equal(f.store.permission(f.id, f.generation, { ...approval, input_preview: '{"command":"different"}' }), null);
  assert.deepEqual(f.store.snapshot(f.id).permissions, []);
});
test('Mac hooks capture only opted-in session text and do not duplicate a channel reply', t => {
  const f = fixture(t), command = f.message();
  f.store.hook(f.id, f.generation, { session_id: 'another', hook_event_name: 'Stop', last_assistant_message: 'PRIVATE OTHER SESSION' });
  f.store.hook(f.id, f.generation, { session_id: f.id, agent_id: 'subagent', hook_event_name: 'Stop', last_assistant_message: 'CHILD' });
  f.store.hook(f.id, f.generation, { session_id: f.id, hook_event_name: 'UserPromptSubmit', prompt_id: 'p1', prompt: 'Mac question' });
  f.store.hook(f.id, f.generation, { session_id: f.id, hook_event_name: 'UserPromptSubmit', prompt_id: 'p1', prompt: 'Mac question' });
  f.store.submit(command); f.store.claim(f.id, f.generation); f.store.reply(f.id, f.generation, command.commandId, 'answer');
  f.store.hook(f.id, f.generation, { session_id: f.id, hook_event_name: 'Stop', last_assistant_message: 'answer' });
  assert.deepEqual(f.store.snapshot(f.id).messages.map(m => m.text), ['Mac question', 'hello', 'answer']);
});
test('snapshot pages preserve ordering and bounded payloads', t => {
  const f = fixture(t);
  for (let i = 0; i < 45; i++) f.store.insertMessage(randomUUID(), f.id, 'user', `Message ${i}`, 'phone');
  const recent = f.store.snapshot(f.id), older = f.store.snapshot(f.id, recent.nextBefore);
  assert.equal(recent.messages.length, 40); assert.equal(older.messages.length, 5); assert.equal(older.nextBefore, null);
  assert.equal(new Set([...older.messages, ...recent.messages].map(m => m.id)).size, 45);
  assert.throws(() => f.store.submit(f.message(randomUUID(), 'a'.repeat(32769))), /too long/);
});

test('session overview returns lightweight project and reply metadata without message bodies', t => {
  const f = fixture(t);
  for (let i = 0; i < 100; i++) f.store.insertMessage(randomUUID(), f.id, 'user', 'private body '.repeat(100), 'phone');
  const initial = f.store.list().data[0];
  assert.equal(initial.lastAssistantSeq, 0);
  assert.equal(typeof initial.cwd, 'string');
  f.store.insertMessage('reply-overview', f.id, 'assistant', 'private reply '.repeat(100), 'mac');
  const first = f.store.list().data[0];
  assert(first.lastAssistantSeq > 0);
  f.store.insertMessage('later-user', f.id, 'user', 'next request', 'phone');
  f.store.heartbeat(f.id, f.generation);
  const next = f.store.list().data[0];
  assert.equal(next.lastAssistantSeq, first.lastAssistantSeq, 'heartbeats and user messages do not create unread completions');
  assert.equal(next.lastAssistantSeq, f.store.snapshot(f.id).messages.find(m => m.id === 'reply-overview').seq);
  assert(JSON.stringify(next).length < 1000);
  assert(!JSON.stringify(next).includes('private'));
});
test('UserPromptSubmit channel echoes do not duplicate the phone message or swallow a Mac prompt', t => {
  const f = fixture(t), command = f.message();
  f.store.submit(command); f.store.claim(f.id, f.generation);
  f.store.hook(f.id, f.generation, { session_id: f.id, prompt_id: 'channel-prompt', hook_event_name: 'UserPromptSubmit',
    prompt: `<channel source="codexlink" message_id="${command.commandId}">\nhello\n</channel>` });
  assert.equal(f.store.snapshot(f.id).messages.length, 1);
  f.store.hook(f.id, f.generation, { session_id: f.id, prompt_id: 'mac-prompt', hook_event_name: 'UserPromptSubmit', prompt: 'hello' });
  assert.deepEqual(f.store.snapshot(f.id).messages.map(m => m.source), ['phone', 'mac']);
});
test('incomplete approval arguments require Mac review, while explicit denial remains possible', t => {
  const f = fixture(t);
  const permissionId = f.store.permission(f.id, f.generation, { ...approval, input_preview: 'command: ... 9000 code points elided ...' });
  const decision = { sessionId: f.id, generation: f.generation, commandId: randomUUID(), action: 'permission', permissionId, behavior: 'allow' };
  assert.throws(() => f.store.submit(decision), /incomplete/);
  assert.equal(f.store.submit({ ...decision, behavior: 'deny' }).status, 'queued');
});
test('dedicated encrypted router keeps Claude operations out of Codex and rejects invented controls', t => {
  const f = fixture(t), router = createClaudeChannelRouter({ stateDir: f.stateDir }), replies = [];
  t.after(() => router.close());
  const send = message => replies.push(JSON.parse(message));
  assert.equal(router.handle(JSON.stringify({ id: 1, method: 'thread/list' }), send), false);
  assert.equal(router.handle(JSON.stringify({ id: 2, method: 'claude/sessions' }), send), true);
  assert.equal(replies[0].result.data[0].id, f.id);
  router.handle(JSON.stringify({ id: 3, method: 'claude/interrupt', params: {} }), send);
  assert.equal(replies[1].error.code, -32601);
});
test('launcher creates isolated per-session config without disabling permission checks', t => {
  const f = fixture(t);
  const prepared = prepareSession({ stateDir: f.stateDir, cwd: '/fixture/project', name: "A ' quoted project", runtime: { root: path.resolve(__dirname, '../..') } });
  assert(prepared.args.includes('--dangerously-load-development-channels'));
  assert(!prepared.args.includes('--dangerously-skip-permissions')); assert(!prepared.args.includes('--permission-mode'));
  const settings = JSON.parse(fs.readFileSync(path.join(prepared.folder, 'hooks.json'), 'utf8'));
  assert.equal(settings.permissions, undefined); assert.equal(settings.env, undefined);
  assert.equal(fs.statSync(path.join(prepared.folder, 'hooks.json')).mode & 0o077, 0);
});
test('state failures return a numeric generic RPC error without disclosing local paths', t => {
  const f = fixture(t), privatePath = path.join(f.stateDir, 'private-state-file');
  fs.writeFileSync(privatePath, 'not a directory');
  const router = createClaudeChannelRouter({ stateDir: privatePath }), replies = [];
  t.after(() => router.close());
  assert.equal(router.handle(JSON.stringify({ id: 1, method: 'claude/sessions' }), raw => replies.push(JSON.parse(raw))), true);
  assert.deepEqual(replies[0], { id: 1, error: { code: -32000, message: 'Claude local state unavailable' } });
});
test('CLI acceptance only auto-approves its exact marker reply in its temporary session', () => {
  const request = { status: 'pending', tool: 'mcp__codexlink__reply', preview: JSON.stringify({ message_id: 'test-id', text: 'TEST_OK' }) };
  assert.equal(isFixtureReply(request, 'test-id', 'TEST_OK'), true);
  assert.equal(isFixtureReply({ ...request, tool: 'Bash' }, 'test-id', 'TEST_OK'), false);
  for (const input of [{ message_id: 'wrong-id', text: 'TEST_OK' }, { message_id: 'test-id', text: 'TEST_OK plus extra' }, { message_id: 'test-id', text: 'TEST_OK', extra: true }]) {
    assert.equal(isFixtureReply({ ...request, preview: JSON.stringify(input) }, 'test-id', 'TEST_OK'), false);
  }
  assert.equal(isFixtureReply({ ...request, preview: 'unparseable TEST_OK test-id' }, 'test-id', 'TEST_OK'), false);
});
test('real stdio MCP process exchanges a message, reply and single-use permission verdict', async t => {
  const f = fixture(t), client = new Client({ name: 'fixture', version: '1.0.0' }, { capabilities: {} });
  const transport = new StdioClientTransport({ command: process.execPath, args: ['--disable-warning=ExperimentalWarning', path.resolve(__dirname, '../bin/claude-channel.js'), '--state-dir', f.stateDir, '--session-id', f.id, '--generation', f.generation], stderr: 'pipe' });
  const seen = [];
  client.setNotificationHandler(z.object({ method: z.literal('notifications/claude/channel'), params: z.object({ content: z.string(), meta: z.object({ message_id: z.string() }) }) }), message => { seen.push(message); });
  client.setNotificationHandler(z.object({ method: z.literal('notifications/claude/channel/permission'), params: z.object({ request_id: z.string(), behavior: z.string() }) }), message => { seen.push(message); });
  try {
    await client.connect(transport);
    assert(client.getServerCapabilities().experimental['claude/channel']);
    assert.deepEqual((await client.listTools()).tools.map(tool => tool.name), ['reply']);
    const command = f.message(); f.store.submit(command);
    const waitUntil = async predicate => { for (let i = 0; i < 100; i++) { if (predicate()) return; await new Promise(r => setTimeout(r, 20)); } throw new Error('Protocol timeout'); };
    await waitUntil(() => seen.length === 1);
    assert.equal(seen[0].params.meta.message_id, command.commandId);
    await client.callTool({ name: 'reply', arguments: { message_id: command.commandId, text: 'from real MCP' } });
    assert.equal(f.store.command(command.commandId, f.id).status, 'replied');
    const forbidden = await client.callTool({ name: 'approve', arguments: { request_id: 'abcde' } }).catch(e => e);
    assert(forbidden instanceof Error || forbidden.isError);
    await client.notification({ method: 'notifications/claude/channel/permission_request', params: approval });
    await waitUntil(() => f.store.snapshot(f.id).permissions.length === 1);
    const permission = f.store.snapshot(f.id).permissions[0];
    f.store.submit({ sessionId: f.id, generation: f.generation, commandId: randomUUID(), action: 'permission', permissionId: permission.id, behavior: 'deny' });
    await waitUntil(() => seen.length === 2);
    assert.deepEqual(seen[1].params, { request_id: 'abcde', behavior: 'deny' });
  } finally { await client.close(); }
});
