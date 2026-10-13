const test = require('node:test');
const assert = require('node:assert/strict');
const { WebSocketServer } = require('ws');
const { once } = require('node:events');
const { createSharedRuntime } = require('../src/shared-runtime');
const { ControlStore } = require('../src/control-store');

test('shared runtime initializes, discovers live threads without overrides, routes queue and never starts another runtime', async () => {
  const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' }); await once(wss, 'listening');
  const calls = []; let peer;
  wss.on('connection', ws => {
    peer = ws;
    ws.on('message', raw => {
      const msg = JSON.parse(raw); calls.push(msg);
      if (msg.id == null) return;
      let result = {};
      if (msg.method === 'thread/loaded/list') result = { data: ['thread-live'], nextCursor: null };
      if (msg.method === 'thread/resume') result = { thread: { id: 'thread-live', cwd: '/repo', turns: [], status: { type: 'active' } } };
      if (msg.method === 'thread/queue/add') result = { queuedSubmission: { id: 'queue-id' } };
      ws.send(JSON.stringify({ id: msg.id, result }));
    });
  });
  const store = new ControlStore(':memory:'); const received = [];
  const runtime = createSharedRuntime({ endpoint: `ws://127.0.0.1:${wss.address().port}`, store });
  runtime.onMessage(raw => received.push(JSON.parse(raw)));
  const until = async fn => { for (let i = 0; i < 200; i++) { if (fn()) return; await new Promise(r => setTimeout(r, 10)); } throw new Error('Timeout'); };
  try {
    await until(() => received.some(e => e.method === 'thread/started'));
    assert.deepEqual(calls.find(c => c.method === 'thread/resume').params, { threadId: 'thread-live', excludeTurns: true });
    runtime.send(JSON.stringify({ id: 'phone-1', method: 'remote/control', params: { commandId: 'queue-command-1', threadId: 'thread-live', action: 'queue', input: [{ type: 'text', text: 'next' }] } }));
    await until(() => received.some(e => e.id === 'phone-1'));
    assert.equal(received.find(e => e.id === 'phone-1').result.status, 'queued');
    assert(!calls.some(c => c.method === 'turn/start'));
    runtime.send(JSON.stringify({ id: 'secret', method: 'getAuthStatus', params: { includeToken: true } }));
    await until(() => received.some(e => e.id === 'secret'));
    assert(received.find(e => e.id === 'secret').error);
    assert(!calls.some(c => c.method === 'getAuthStatus'));
    runtime.send(JSON.stringify({ id: 'terminal', method: 'remote/openOnMac', params: {
      threadId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', requestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    } }));
    await until(() => received.some(e => e.id === 'terminal'));
    assert.equal(received.find(e => e.id === 'terminal').result.status, 'failed');
    assert(!calls.some(c => c.method === 'remote/openOnMac'));

  } finally { runtime.shutdown(); peer?.terminate(); await new Promise(r => wss.close(r)); store.close(); }
});

test('daemon connection loss reattaches and deduplicates an uncertain command without replaying it', async () => {
  const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' }); await once(wss, 'listening');
  let connections = 0, queueCalls = 0, resumes = 0; const peers = new Set();
  wss.on('connection', ws => {
    connections++; peers.add(ws); ws.on('close', () => peers.delete(ws));
    ws.on('message', raw => {
      const msg = JSON.parse(raw); if (msg.id == null) return;
      let result = {};
      if (msg.method === 'thread/loaded/list') result = { data: ['live'], nextCursor: null };
      if (msg.method === 'thread/resume') { resumes++; result = { thread: { id: 'live', turns: [] } }; }
      if (msg.method === 'thread/queue/add') { queueCalls++; ws.terminate(); return; }
      ws.send(JSON.stringify({ id: msg.id, result }));
    });
  });
  const store = new ControlStore(':memory:'); const received = [];
  const runtime = createSharedRuntime({ endpoint: `ws://127.0.0.1:${wss.address().port}`, store });
  runtime.onMessage(raw => received.push(JSON.parse(raw)));
  const until = async fn => { for (let i = 0; i < 400; i++) { if (fn()) return; await new Promise(r => setTimeout(r, 10)); } throw new Error('Timeout'); };
  const params = { commandId: 'reconnect-command', threadId: 'live', action: 'queue', input: [{ type: 'text', text: 'once' }] };
  try {
    await until(() => resumes === 1);
    runtime.send(JSON.stringify({ id: 'first', method: 'remote/control', params }));
    await until(() => received.some(e => e.id === 'first'));
    assert.equal(received.find(e => e.id === 'first').result.status, 'unknown');
    await until(() => connections === 2 && resumes === 2);
    runtime.send(JSON.stringify({ id: 'retry', method: 'remote/control', params }));
    await until(() => received.some(e => e.id === 'retry'));
    assert.equal(received.find(e => e.id === 'retry').result.status, 'unknown');
    assert.equal(queueCalls, 1);
    runtime.send(JSON.stringify({ id: 99, result: { decision: 'acceptForSession' } }));
    await until(() => received.some(e => e.id === 99));
    assert.match(received.find(e => e.id === 99).error.message, /durable commandId/);
  } finally { runtime.shutdown(); for (const ws of peers) ws.terminate(); await new Promise(r => wss.close(r)); store.close(); }
});
