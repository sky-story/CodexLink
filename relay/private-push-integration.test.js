const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const WebSocket = require('ws');
const { createRelayServer } = require('./server');

test('private provider injection preserves live-session auth and routes one notification without external network', async () => {
  let state = { sessions: [], deliveredDedupeKeys: [] };
  const sent = [];
  const { server, wss } = createRelayServer({ enablePushService: true,
    apnsClient: { isConfigured: () => true, sendNotification: async p => { sent.push(p); return { ok: true }; } },
    pushStateStore: { read: () => state, write: value => { state = value; } },
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}`;
  let mac;
  const post = async (endpoint, payload) => fetch(`${url}/v1/push/session/${endpoint}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload),
  });
  const credentials = { sessionId: 'private-push-fixture', notificationSecret: 'test-only-secret' };
  try {
    mac = new WebSocket(`${url.replace('http:', 'ws:')}/relay/${credentials.sessionId}`, {
      headers: { 'x-role': 'mac', 'x-notification-secret': credentials.notificationSecret },
    });
    await once(mac, 'open');
    const registration = { ...credentials, deviceToken: 'aabbcc', alertsEnabled: true, apnsEnvironment: 'development' };
    assert.equal((await post('register-device', { ...registration, notificationSecret: 'wrong' })).status, 403);
    assert.equal((await post('register-device', registration)).status, 200);
    const message = { ...credentials, threadId: 'fixture-thread', turnId: 'fixture-turn', result: 'approval', dedupeKey: 'fixture-once', body: 'Approval required' };
    assert.equal((await post('notify-completion', message)).status, 200);
    assert.equal((await post('notify-completion', message)).status, 200);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].apnsEnvironment, 'development');
    assert.equal(sent[0].payload.threadId, 'fixture-thread');
    const closed = once(mac, 'close'); mac.close(); await closed;
    assert.equal((await post('notify-completion', { ...message, dedupeKey: 'after-disconnect' })).status, 403);
  } finally {
    mac?.terminate(); for (const client of wss.clients) client.terminate();
    await new Promise(resolve => wss.close(resolve));
    await new Promise(resolve => server.close(resolve));
  }
});
