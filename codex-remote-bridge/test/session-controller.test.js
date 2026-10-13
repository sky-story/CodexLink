require('./helpers/isolated-state.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ControlStore } = require('../src/control-store');
const { SessionController } = require('../src/session-controller');
const { socketURL } = require('../src/shared-runtime');
const command = (action = 'steer', extra = {}) => ({ commandId: 'command-1234', threadId: 'thread-A', action, expectedTurnId: 'turn-A', input: [{ type: 'text', text: 'change direction' }], ...extra });
function harness(rpc) { const store = new ControlStore(':memory:'); const events = []; return { store, events, controller: new SessionController({ store, rpc, emit: e => events.push(e) }) }; }

test('steer preserves expectedTurnId, never starts a turn, duplicate concurrent input executes once', async () => {
  const calls = [];
  const { controller, store } = harness(async (method, params) => { calls.push({ method, params }); return { turnId: 'turn-A' }; });
  const [a, b] = await Promise.all([controller.submit(command()), controller.submit(command())]);
  assert.equal(calls.length, 1); assert.equal(calls[0].method, 'turn/steer'); assert.equal(calls[0].params.expectedTurnId, 'turn-A'); assert.equal(a.status, 'accepted'); assert.deepEqual(a, b); store.close();
});
test('queue uses server durable queue with stable client ID, not turn/start or steer', async () => {
  const calls = []; const { controller, store } = harness(async (m, p) => { calls.push([m,p]); return { queuedSubmission: { id: 'q' } }; });
  assert.equal((await controller.submit(command('queue'))).status, 'queued');
  assert.equal(calls[0][0], 'thread/queue/add'); assert.equal(calls[0][1].clientUserMessageId, 'command-1234'); store.close();
});
test('turn mismatch fails explicitly and does not fall back to another turn', async () => {
  let count = 0; const { controller, store } = harness(async () => { count++; throw Object.assign(new Error('turn mismatch'), { code: -32602 }); });
  assert.equal((await controller.submit(command())).status, 'failed'); assert.equal(count, 1); store.close();
});
test('connection loss gives unknown receipt and never auto-retries', async () => {
  let count = 0; const { controller, store } = harness(async () => { count++; throw new Error('socket closed after send'); });
  assert.equal((await controller.submit(command())).status, 'unknown');
  assert.equal((await controller.submit(command())).status, 'unknown'); assert.equal(count, 1); store.close();
});
test('input event before response cannot be downgraded from observed to accepted', async () => {
  let controller; const fixture = harness(async () => { controller.observe({ method: 'item/started', params: { threadId: 'thread-A', turnId: 'turn-A', item: { type: 'userMessage', clientId: 'command-1234' } } }); return { turnId: 'turn-A' }; }); controller = fixture.controller;
  assert.equal((await controller.submit(command())).status, 'observed'); fixture.store.close();
});
test('fast Queue input before RPC response preserves the observed Turn ID', async () => {
  let controller;
  const fixture = harness(async () => {
    controller.observe({ method: 'item/started', params: { threadId: 'thread-A', turnId: 'queued-turn', item: { type: 'userMessage', clientId: 'command-1234' } } });
    return { queuedSubmission: { id: 'queue-entry' } };
  });
  controller = fixture.controller;
  try {
    const receipt = await controller.submit(command('queue', { expectedTurnId: undefined }));
    assert.equal(receipt.status, 'observed');
    assert.equal(receipt.turnId, 'queued-turn');
  } finally { fixture.store.close(); }
});
test('official input observed before response loss remains observed and is never resent', async () => {
  let controller, calls = 0;
  const fixture = harness(async () => {
    calls++;
    controller.observe({ method: 'item/started', params: { threadId: 'thread-A', turnId: 'queued-turn', item: { type: 'userMessage', clientId: 'command-1234' } } });
    throw new Error('socket closed before response');
  });
  controller = fixture.controller;
  try {
    const request = command('queue', { expectedTurnId: undefined });
    const receipt = await controller.submit(request);
    assert.equal(receipt.status, 'observed');
    assert.equal(receipt.turnId, 'queued-turn');
    assert.deepEqual(await controller.submit(request), receipt);
    assert.equal(calls, 1);
  } finally { fixture.store.close(); }
});
test('same command ID with different payload is rejected', async () => {
  const { controller, store } = harness(async () => ({ turnId: 'turn-A' }));
  await controller.submit(command()); await assert.rejects(controller.submit(command('queue')), /different input/); store.close();
});
test('only pending matching approval can be answered once', async () => {
  let calls = 0; const { controller, store } = harness(async () => { calls++; return {}; });
  controller.observe({ id: 7, method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-A' } });
  assert.equal((await controller.submit(command('approval', { requestId: 7, decision: 'accept' }))).status, 'sent');
  assert.equal((await controller.submit(command('approval', { commandId: 'command-5678', requestId: 7, decision: 'accept' }))).status, 'failed'); assert.equal(calls, 1); store.close();
});
test('crash recovery marks dispatch intent unknown, preserves replay order and receipts', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-control-test-')); const file = path.join(dir, 'state.sqlite');
  let store = new ControlStore(file); store.begin(command()); store.append({ method: 'first' }); store.append({ method: 'second' }); store.close();
  store = new ControlStore(file); assert.equal(store.get('command-1234').status, 'unknown'); assert.deepEqual(store.replay(0).events.map(e => e.event.method), ['first', 'second']); assert.equal(store.replay(1).events.length, 1); store.close(); fs.rmSync(dir, { recursive: true });
});
test('upstream rejects unencrypted nonlocal endpoints', () => {
  assert.equal(socketURL('unix:///tmp/codex.sock'), 'ws+unix:///tmp/codex.sock:/');
  assert.throws(() => socketURL('ws://192.168.1.1:1234'), /local/);
});
test('only one controller may own a state directory and ownership releases on close', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-owner-test-')); const file = path.join(dir, 'control.sqlite');
  const first = new ControlStore(file);
  assert.throws(() => new ControlStore(file), /already running/);
  first.close(); const next = new ControlStore(file); next.close(); fs.rmSync(dir, { recursive: true });
});

test('structured input is sent once and only resolved notification confirms completion', async () => {
  const calls = []; const { controller, store } = harness(async (m, p) => { calls.push([m, p]); return {}; });
  controller.observe({ id: 'question', method: 'item/tool/requestUserInput', params: { threadId: 'thread-A' } });
  const request = command('input', { requestId: 'question', answers: { q: { answers: ['yes'] } } });
  assert.equal((await controller.submit(request)).status, 'sent');
  assert.equal((await controller.submit(request)).status, 'sent');
  assert.deepEqual(calls, [[null, { id: 'question', result: { answers: request.answers } }]]);
  controller.observe({ method: 'serverRequest/resolved', params: { requestId: 'question' } });
  assert.equal(store.get(request.commandId).status, 'observed'); store.close();
});

test('model settings use catalog validation, a narrow next-turn update, readback and durable deduplication', async () => {
  const store = new ControlStore(':memory:'); const calls = [];
  const controller = new SessionController({ store, rpc: async (method, params) => {
    calls.push({ method, params });
    if (method === 'model/list') return params.cursor ? { data: [{ model: 'fixture-model', supportedReasoningEfforts: [{ reasoningEffort: 'high' }] }], nextCursor: null } : { data: [], nextCursor: 'page2' };
    if (method === 'thread/settings/update') return {};
    if (method === 'thread/read') return { thread: { id: 'thread', model: 'fixture-model', reasoningEffort: 'high' } };
    assert.fail(method);
  }});
  const command = { commandId: 'settings-once', threadId: 'thread', action: 'settings', model: 'fixture-model', effort: 'high' };
  try {
    const [a,b] = await Promise.all([controller.submit(command), controller.submit(command)]);
    assert.equal(a.status, 'applied'); assert.deepEqual(a, b);
    assert.deepEqual(a.result, { model: 'fixture-model', effort: 'high' });
    assert.deepEqual(calls.find(c => c.method === 'thread/settings/update').params, { threadId: 'thread', model: 'fixture-model', effort: 'high' });
    assert.equal(calls.filter(c => c.method === 'thread/settings/update').length, 1);
    assert.deepEqual(await new SessionController({ store, rpc: async () => assert.fail('must not resend') }).submit(command), a);
  } finally { store.close(); }
});

test('settings reject permission injection and unsupported model/effort before mutation', async () => {
  const store = new ControlStore(':memory:'); const calls = [];
  const controller = new SessionController({ store, rpc: async method => { calls.push(method); return { data: [{ model: 'fixture', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }], nextCursor: null }; }});
  const command = { commandId: 'settings-denied', threadId: 'thread', action: 'settings', model: 'fixture', effort: 'high' };
  try {
    await assert.rejects(controller.submit({ ...command, sandboxPolicy: { type: 'dangerFullAccess' } }), /permission/);
    await assert.rejects(controller.submit({ ...command, effort: null }), /required/);
    assert.equal(calls.length, 0);
    assert.equal((await controller.submit(command)).status, 'failed');
    assert.deepEqual(calls, ['model/list']);
  } finally { store.close(); }
});

test('unconfirmed settings stay unknown and cannot be automatically applied again', async () => {
  for (const readback of [async () => { throw Object.assign(new Error('read failed'), { code: -32601 }); }, async () => ({ thread: { id: 'thread', model: 'different', reasoningEffort: 'low' } })]) {
    const store = new ControlStore(':memory:'); let updates = 0;
    const controller = new SessionController({ store, rpc: async method => {
      if (method === 'model/list') return { data: [{ model: 'fixture', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }] };
      if (method === 'thread/settings/update') { updates++; return {}; }
      return readback();
    }});
    const command = { commandId: 'settings-unknown', threadId: 'thread', action: 'settings', model: 'fixture', effort: 'low' };
    try { assert.equal((await controller.submit(command)).status, 'unknown'); assert.equal((await controller.submit(command)).status, 'unknown'); assert.equal(updates, 1); }
    finally { store.close(); }
  }
});
