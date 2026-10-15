const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadBarkConfig, sendBark, eventNotice, createBarkNotifications, DEFAULT_BARK_ICONS } = require('../src/bark-push');
const config = { enabled: true, reason: 'configured', endpoint: 'https://example.test/push', deviceKey: 'fixtureKeyOnly123' };
const completed = { method: 'turn/completed', params: { threadId: 'private-thread', turn: { id: 'turn1', status: 'completed', items: [{ text: 'PRIVATE CODE' }] } } };
function fixture(t) { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-test-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; }
const accepted = async () => ({ ok: true, status: 200, json: async () => ({ code: 200 }) });
test('configuration absent, disabled, malformed or insecure only disables Bark', t => {
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json');
  assert.equal(loadBarkConfig({ stateDir }).reason, 'not_configured');
  for (const value of [null, { enabled: false }, { enabled: true }, { enabled: true, serverUrl: 'http://example.test', deviceKey: 'fixture123' }, { enabled: true, serverUrl: 'https://example.test/?secret=1', deviceKey: 'fixture123' }]) {
    fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 }); assert.equal(loadBarkConfig({ stateDir }).enabled, false);
  }
  fs.writeFileSync(file, JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: 'fixture123' }));
  assert.equal(loadBarkConfig({ stateDir }).enabled, true);
  fs.chmodSync(file, 0o644); assert.equal(loadBarkConfig({ stateDir }).reason, 'config_permissions_must_be_600');
});
test('payload uses fixed generic text; no thread, command, title or approval content leaves Mac', async t => {
  const sent = [], report = [];
  const notifier = createBarkNotifications({ stateDir: fixture(t), config, report: x => report.push(x), fetchImpl: async (url, options) => { sent.push({ url, options }); return accepted(); } });
  await notifier.handleOutbound(completed);
  const { url, options } = sent[0];
  assert.equal(url, 'https://example.test/push'); assert.equal(options.redirect, 'error');
  assert.equal(options.method, 'POST'); assert(options.signal);
  const payload = JSON.parse(options.body);
  assert.deepEqual(Object.keys(payload).sort(), ['body','device_key','group','isArchive','title']);
  assert.equal(payload.title, 'CodexLink'); assert.match(payload.body, /已完成/);
  assert(!options.body.includes('private-thread')); assert(!options.body.includes('PRIVATE CODE'));
  assert(!JSON.stringify(report).includes(config.deviceKey));
});
test('duplicate event, parallel event and restart send once; persisted journal contains no key/content', async t => {
  const stateDir = fixture(t); let sends = 0;
  const options = { stateDir, config, report: () => {}, fetchImpl: async () => { sends++; return accepted(); } };
  const notifier = createBarkNotifications(options);
  await Promise.all([notifier.handleOutbound(completed), notifier.handleOutbound(completed)]);
  await createBarkNotifications(options).handleOutbound(completed);
  assert.equal(sends, 1);
  const { NotificationStore } = require('../src/notification-store');
  const store = new NotificationStore(stateDir);
  const ledger = JSON.stringify(store.db.prepare('SELECT * FROM notices').all());
  store.close();
  assert(!ledger.includes(config.deviceKey)); assert(!ledger.includes('PRIVATE')); assert(!ledger.includes('private-thread'));
  assert.equal(fs.statSync(path.join(stateDir, 'notification-deliveries.sqlite')).mode & 0o077, 0);
});
test('transport uncertainty and server rejection are redacted and never replayed', async t => {
  for (const fetchImpl of [async () => { throw new Error(config.deviceKey); }, async () => ({ ok: false, status: 500 }), async () => ({ ok: true, status: 200, json: async () => ({ code: 400, message: config.deviceKey }) })]) {
    const result = await sendBark(config, 'test', { fetchImpl }); assert.notEqual(result.status, 'accepted');
    assert(!JSON.stringify(result).includes(config.deviceKey));
  }
  const stateDir = fixture(t); let sends = 0;
  const options = { stateDir, config, report: () => {}, fetchImpl: async () => { sends++; throw new Error(config.deviceKey); } };
  await createBarkNotifications(options).handleOutbound(completed);
  await createBarkNotifications(options).handleOutbound(completed);
  assert.equal(sends, 1);
});
test('approval/input require original request identity; deltas, snapshots and resolved events do not notify', async t => {
  const stateDir = fixture(t), sent = [];
  const notifier = createBarkNotifications({ stateDir, config, report: () => {}, fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  for (const method of ['item/commandExecution/requestApproval','item/fileChange/requestApproval','item/permissions/requestApproval','item/tool/requestUserInput']) {
    const message = { id: method, method, params: { threadId: 'thread', turnId: 'turn', itemId: 'item', command: 'PRIVATE COMMAND' } };
    await notifier.handleOutbound(message); await notifier.handleOutbound(message);
  }
  assert.equal(sent.length, 4); assert(!JSON.stringify(sent).includes('PRIVATE'));
  for (const message of [null, '{broken', { method: 'serverRequest/resolved' }, { method: 'thread/started', params: { threadId: 'thread', thread: completed.params } }, { method: 'item/commandExecution/requestApproval', params: { threadId: 'thread' } }]) assert.equal(eventNotice(message), null);
});
test('failed and interrupted Turn have distinct generic text; success does not claim delivery', async () => {
  for (const status of ['failed','interrupted']) {
    assert.equal(eventNotice({ ...completed, params: { ...completed.params, turn: { id: 'turn1', status } } }).kind, status);
  }
  assert.deepEqual(await sendBark(config, 'completed', { fetchImpl: accepted }), { status: 'accepted', httpStatus: 200 });
  await assert.rejects(sendBark(config, 'custom private message'));
});
test('invalid durable ledger disables only Bark and makes no network call', async t => {
  const stateDir = fixture(t); fs.writeFileSync(path.join(stateDir, 'bark-deliveries.json'), 'broken');
  let sends = 0; const reports = [];
  const notifier = createBarkNotifications({ stateDir, config, report: x => reports.push(x), fetchImpl: async () => { sends++; return accepted(); } });
  await notifier.handleOutbound(completed);
  assert.equal(sends, 0); assert.equal(reports[0].reason, 'invalid_delivery_ledger');
});

test('opt-in labels distinguish concurrent same-name threads and keep messages/paths out of payload', async t => {
  const sent = [], threads = ['01a13508-0000-7000-8000-000000000001', '01a13508-0000-7000-8000-000000000002'];
  const notifier = createBarkNotifications({ stateDir: fixture(t), config: { ...config, includeSessionLabel: true }, report: () => {},
    readThread: async id => ({ id, name: '待办 App', cwd: '/Users/private/project', preview: 'SECRET USER PROMPT' }),
    fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  await Promise.all(threads.map(threadId => notifier.handleOutbound({ ...completed, params: { ...completed.params, threadId } })));
  assert.equal(sent.length, 2); assert.notEqual(sent[0].body, sent[1].body); assert.notEqual(sent[0].group, sent[1].group);
  for (const payload of sent) {
    assert.equal(payload.title, 'Codex · 任务已完成');
    assert.match(payload.body, /^待办 App · [a-f0-9]{8}$/);
    for (const secret of ['SECRET USER PROMPT', '/Users/', 'PRIVATE CODE', ...threads]) assert(!JSON.stringify(payload).includes(secret));
  }
});
test('missing names fall back to project basename then stable short identity, never conversation preview', () => {
  const { sessionPresentation } = require('../src/bark-push');
  const a = sessionPresentation({ threadId: 'thread-A', cwd: '/private/parent/my-project/', preview: 'SECRET PROMPT' });
  assert.match(a.body, /^my-project · /); assert(!a.body.includes('/private'));
  const b = sessionPresentation({ threadId: 'thread-B', preview: 'SECRET PROMPT' });
  assert.match(b.body, /^未命名会话 · /);
  assert.equal(sessionPresentation({ threadId: 'thread-B' }).group, b.group);
});
test('latest metadata lookup and official rename event both update labels', async t => {
  const sent = []; let currentName = '最新名称', failRead = false;
  const notifier = createBarkNotifications({ stateDir: fixture(t), config: { ...config, includeSessionLabel: true }, report: () => {},
    readThread: async id => { if (failRead) throw new Error('offline'); return { id, name: currentName }; },
    fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  await notifier.handleOutbound({ method: 'thread/started', params: { thread: { id: 'private-thread', name: '旧名称' } } });
  await notifier.handleOutbound(completed);
  assert.match(sent[0].body, /最新名称/);
  failRead = true;
  await notifier.handleOutbound({ method: 'thread/name/updated', params: { threadId: 'private-thread', threadName: '重命名会话' } });
  await notifier.handleOutbound({ ...completed, params: { ...completed.params, turn: { id: 'next', status: 'completed' } } });
  assert.match(sent[1].body, /重命名会话/); assert.equal(sent[0].group, sent[1].group);
});
test('metadata timeout and wrong-thread metadata still notify with safe fallback', async t => {
  for (const readThread of [async () => new Promise(() => {}), async () => ({ id: 'other-thread', name: 'WRONG SECRET NAME' })]) {
    const sent = [];
    const notifier = createBarkNotifications({ stateDir: fixture(t), config: { ...config, includeSessionLabel: true }, report: () => {}, readThread, metadataTimeoutMs: 5,
      fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
    await notifier.handleOutbound(completed);
    assert.equal(sent.length, 1); assert.match(sent[0].body, /未命名会话/); assert(!sent[0].body.includes('WRONG'));
  }
});
test('long/control-character labels are bounded; approval and completion group by the same thread', async t => {
  const sent = [];
  const notifier = createBarkNotifications({ stateDir: fixture(t), config: { ...config, includeSessionLabel: true }, report: () => {},
    readThread: async id => ({ id, name: '示例\n\u202e' + '🍎'.repeat(70) }),
    fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  await notifier.handleOutbound(completed);
  await notifier.handleOutbound({ id: 9, method: 'item/commandExecution/requestApproval', params: { threadId: 'private-thread', turnId: 't', itemId: 'i', command: 'SECRET CMD' } });
  assert.equal(sent.length, 2); assert.equal(sent[0].group, sent[1].group); assert.equal(sent[0].title, 'Codex · 任务已完成'); assert.equal(sent[1].title, 'Codex · 等待审批'); assert.equal(sent[0].body, sent[1].body);
  assert(Array.from(sent[0].body).length < 70); assert(!/[\n\u202e]/.test(sent[0].body)); assert(!JSON.stringify(sent).includes('SECRET CMD'));
});
test('labels remain opt-in; disabling skips metadata lookup and sends original generic payload', async t => {
  let lookups = 0; const sent = [];
  const notifier = createBarkNotifications({ stateDir: fixture(t), config, report: () => {},
    readThread: async () => { lookups++; return { name: 'PRIVATE NAME' }; },
    fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
  await notifier.handleOutbound(completed);
  assert.equal(lookups, 0); assert.equal(sent[0].title, 'CodexLink'); assert.equal(sent[0].group, 'Codex Remote');
});

test('optional icons validate independently; bad artwork never disables Bark or changes its receiver', t => {
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json');
  for (const invalid of [null, 42, {}, 'file:///private/icon.png', 'http://example.test/icon.png',
    'https://user:secret@example.test/icon.png', 'https://example.test/icon.png#fragment', 'https://example.test/\nicon.png']) {
    fs.writeFileSync(file, JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey,
      icons: { codex: invalid, claude: DEFAULT_BARK_ICONS.claude, unknown: 'https://example.test/unknown.png' } }), { mode: 0o600 });
    const loaded = loadBarkConfig({ stateDir });
    assert.equal(loaded.enabled, true); assert.equal(loaded.deviceKey, config.deviceKey);
    assert.deepEqual(loaded.icons, { claude: DEFAULT_BARK_ICONS.claude });
  }
});

test('one shared dispatcher uses each queued provider icon, including legacy rows and disabled labels', async t => {
  const { NotificationStore } = require('../src/notification-store');
  for (const includeSessionLabel of [true, false]) {
    const stateDir = fixture(t), sent = [], store = new NotificationStore(stateDir);
    // Rows created before icons existed still receive the current icon at send time.
    for (const [provider, id, kind] of [['codex', 'a', 'completed'], ['claude', 'b', 'response_ready']]) {
      store.enqueue({ provider, id: id.repeat(64), kind, presentation: { title: provider, body: 'safe label', group: provider, icon: 'https://example.test/stale.png' } });
    }
    store.close();
    const notifier = createBarkNotifications({ stateDir, config: { ...config, includeSessionLabel, icons: DEFAULT_BARK_ICONS }, report: () => {},
      fetchImpl: async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); } });
    await notifier.drain(); await notifier.close();
    assert.equal(sent.length, 2);
    assert.deepEqual(sent.map(p => p.icon).sort(), Object.values(DEFAULT_BARK_ICONS).sort());
    for (const payload of sent) {
      assert.equal(payload.icon, payload.group.toLowerCase().startsWith('claude') ? DEFAULT_BARK_ICONS.claude : DEFAULT_BARK_ICONS.codex);
    }
  }
});

test('explicit source tests use matching titles/icons; missing or removed icons omit the field', async () => {
  const sent = [], fetchImpl = async (_, options) => { sent.push(JSON.parse(options.body)); return accepted(); };
  for (const provider of ['codex', 'claude']) {
    await sendBark({ ...config, icons: DEFAULT_BARK_ICONS }, 'test', { provider, fetchImpl });
    assert.equal(sent.at(-1).icon, DEFAULT_BARK_ICONS[provider]);
    assert.equal(sent.at(-1).title, `${provider === 'codex' ? 'Codex' : 'Claude'} · 通知测试`);
    for (const icons of [undefined, {}, { [provider]: 'file:///secret' }]) {
      await sendBark({ ...config, icons }, 'test', { provider, fetchImpl });
      assert.equal(Object.hasOwn(sent.at(-1), 'icon'), false);
    }
  }
});

test('icon CLI preserves keys, labels and the other icon; status and failures redact private values', t => {
  const { spawnSync } = require('node:child_process');
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json');
  const original = { enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey, includeSessionLabel: true, futureSetting: 'retained' };
  fs.writeFileSync(file, JSON.stringify(original), { mode: 0o600 });
  const run = (...args) => spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', path.resolve(__dirname, '../../scripts/bark-notifications.cjs'), ...args], {
    env: { ...process.env, CODEX_REMOTE_DEVICE_STATE_DIR: stateDir }, encoding: 'utf8', timeout: 5000,
  });
  for (const provider of ['codex', 'claude']) assert.equal(run('--icon', provider, 'default').status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { ...original, icons: DEFAULT_BARK_ICONS });
  const custom = 'https://example.test/private-image.png?token=PRIVATE_TOKEN';
  const update = run('--icon', 'codex', custom);
  assert.equal(update.status, 0); assert(!update.stdout.includes(custom));
  const status = run('--status');
  assert.deepEqual(JSON.parse(status.stdout).icons, { codex: true, claude: true });
  assert(!status.stdout.includes('PRIVATE')); assert(!status.stdout.includes(config.deviceKey));
  const before = fs.readFileSync(file, 'utf8');
  const bad = run('--icon', 'codex', 'https://user:PRIVATE_SECRET@example.test/a.png');
  assert.equal(bad.status, 1); assert(!bad.stderr.includes('PRIVATE')); assert.equal(fs.readFileSync(file, 'utf8'), before);
  assert.equal(run('--icon', 'claude', 'off').status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { ...original, icons: { codex: custom } });
  assert.equal(fs.statSync(file).mode & 0o077, 0);
});
