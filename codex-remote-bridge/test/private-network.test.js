require('./helpers/isolated-state.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { addressFromStatus, readTailscaleAddress, readTailscaleAddressAsync, startPrivateNetwork } = require('../src/private-network');
async function fixture(overrides = {}) {
  const calls = [], statuses = [], exits = [];
  let address = null, tick;
  const server = new EventEmitter();
  server.listen = (port, host, fn) => { calls.push({ port, host }); fn(); };
  server.close = () => {};
  const options = { config: { privateRelayEnabled: true, relayUrl: 'ws://ignored.example/relay' },
    readAddress: () => address, createRelay: () => ({ server }), startBridge: value => calls.push(value),
    publishStatus: value => statuses.push(value), exit: code => exits.push(code),
    schedule: fn => { tick = fn; return 'timer'; }, cancel: () => {},
    readPush: () => ({ enabled: false, reason: 'not_configured' }), reportPush: () => {}, reportError: () => {},
    ...overrides,
  };
  const instance = startPrivateNetwork(options);
  await instance.ready;
  return { instance, server, calls, statuses, exits, tick: () => tick(), address: value => { address = value; } };
}
test('Tailscale status only permits an active CGNAT IPv4 binding', () => {
  for (const ip of ['0.0.0.0', '127.0.0.1', '192.168.1.2', '100.63.2.3', '100.128.2.3', '100.64.999.1']) {
    assert.equal(addressFromStatus({ BackendState: 'Running', TailscaleIPs: [ip] }), null);
  }
  assert.equal(addressFromStatus({ BackendState: 'Stopped', TailscaleIPs: ['100.64.1.2'] }), null);
  assert.equal(addressFromStatus({ BackendState: 'Running', TailscaleIPs: ['::1', '100.64.1.2'] }), '100.64.1.2');
});
test('private APNs uses the existing private listener and never a second public service', async () => {
  let relayOptions;
  const f = await fixture({ readPush: () => ({ enabled: true, reason: 'configured' }),
    pushOptions: () => ({ enablePushService: true }),
    createRelay: options => { relayOptions = options; return { server: f.server }; } });
  f.address('100.64.1.2'); await f.tick();
  assert.deepEqual(relayOptions, { enablePushService: true });
  assert.equal(f.calls[1].config.pushServiceUrl, 'http://100.64.1.2:9100');
  assert.equal(f.calls[1].config.pushPreviewMaxChars, 0);
  assert.deepEqual(f.calls[0], { host: '100.64.1.2', port: 9100 });
  f.instance.stop();
});
test('invalid optional push configuration leaves normal private Bridge running with push disabled', async () => {
  const f = await fixture({ readPush: () => ({ enabled: false, reason: 'invalid_config_json' }) });
  f.address('100.64.1.2'); await f.tick();
  assert.equal(f.calls[1].config.pushServiceUrl, '');
  assert.deepEqual(f.exits, []); f.instance.stop();
});
test('Mac app CLI is preferred over unrelated Homebrew daemon CLI', () => {
  let invocation;
  const ip = readTailscaleAddress({ env: { XPC_SERVICE_NAME: 'com.codexremote.bridge', HOME: '/test' }, exists: () => true, exec: (...args) => { invocation = args; return JSON.stringify({ BackendState: 'Running', TailscaleIPs: ['100.64.1.2'] }); } });
  assert.equal(ip, '100.64.1.2'); assert.equal(invocation[0], '/Applications/Tailscale.app/Contents/MacOS/Tailscale');
  assert.deepEqual(invocation[1], ['status', '--json']); assert.equal(invocation[2].timeout, 10000);
  assert.equal(invocation[2].env.XPC_SERVICE_NAME, undefined); assert.equal(invocation[2].env.HOME, '/test');
  assert.equal(invocation[2].env.TAILSCALE_BE_CLI, '1');
});
test('offline startup waits without binding; online starts one private Relay and Bridge', async () => {
  const f = await fixture(); assert.equal(f.statuses.at(-1).state, 'waiting-network'); assert.equal(f.calls.length, 0);
  f.address('100.64.1.2'); await f.tick(); await f.tick();
  assert.equal(f.calls.length, 2); assert.deepEqual(f.calls[0], { port: 9100, host: '100.64.1.2' });
  assert.equal(f.calls[1].config.relayUrl, 'ws://100.64.1.2:9100/relay'); assert.equal(f.calls[1].printPairingQr, false);
  f.instance.stop();
});
test('network loss triggers one restart and never switches to a public or LAN listener', async () => {
  const f = await fixture(); f.address('100.64.1.2'); await f.tick(); f.address('192.168.1.2'); await f.tick(); await f.tick();
  assert.deepEqual(f.exits, [1]); assert.equal(f.calls.length, 2); assert.match(f.statuses.at(-1).lastError, /Tailscale/);
});
test('address changes force rebind through service restart, preserving config and trust externally', async () => {
  const f = await fixture(); f.address('100.64.1.2'); await f.tick(); f.address('100.64.1.3'); await f.tick();
  assert.deepEqual(f.exits, [1]); assert.equal(f.calls.length, 2);
});
test('occupied port fails without starting a second Bridge', async () => {
  const f = await fixture(); f.server.listen = () => f.server.emit('error', new Error('EADDRINUSE'));
  f.address('100.64.1.2'); await f.tick(); assert.deepEqual(f.exits, [1]); assert.equal(f.calls.length, 0);
});

test('asynchronous Mac CLI probe lets the event loop run while status is pending', async () => {
  let finish, invocation;
  const probe = readTailscaleAddressAsync({ exists: () => true, env: { XPC_SERVICE_NAME: 'fixture' },
    exec: (...args) => { invocation = args; finish = args.at(-1); } });
  let ticked = false;
  await new Promise(resolve => setImmediate(() => { ticked = true; resolve(); }));
  assert(ticked);
  assert.equal(invocation[2].env.XPC_SERVICE_NAME, undefined);
  assert.equal(invocation[2].killSignal, 'SIGKILL');
  finish(null, JSON.stringify({ BackendState: 'Running', TailscaleIPs: ['100.64.1.2'] }));
  assert.equal(await probe, '100.64.1.2');
});

test('a slow probe never overlaps and a stopped service ignores its late result', async () => {
  let finish, reads = 0;
  const f = await fixture();
  f.instance.stop();
  const service = startPrivateNetwork({ config: {}, readAddress: () => { reads++; return new Promise(r => { finish = r; }); },
    startBridge: () => assert.fail('must not start after stop'), createRelay: () => assert.fail('must not bind after stop'),
    schedule: () => 1, cancel: () => {}, reportError: () => {} });
  await service.check(); await service.check();
  assert.equal(reads, 1);
  service.stop(); finish('100.64.1.2'); await service.ready;
});

test('transient CLI failures retain the listener and successful probes reset the failure count', async () => {
  let failing = false;
  const f = await fixture({ readAddress: () => {
    if (failing) throw Object.assign(new Error('fixture timeout'), { code: 'ETIMEDOUT' });
    return '100.64.1.2';
  } });
  failing = true; await f.tick(); await f.tick();
  assert.deepEqual(f.exits, []);
  failing = false; await f.tick();
  failing = true; await f.tick(); await f.tick();
  assert.deepEqual(f.exits, []);
  await f.tick(); await f.tick();
  assert.deepEqual(f.exits, [1]);
  assert.equal(f.calls.length, 2);
  assert.match(f.statuses.at(-1).lastError, /3 probes/);
});

test('malformed status is an unavailable probe, not proof of a changed address', async () => {
  await assert.rejects(readTailscaleAddressAsync({ exec: (...args) => args.at(-1)(null, '{}') }), /Invalid Tailscale status/);
});
