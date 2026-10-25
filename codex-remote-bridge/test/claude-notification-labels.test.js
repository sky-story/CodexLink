const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { recordClaudeHook } = require('../src/claude-notifications');
const { NotificationStore } = require('../src/notification-store');
const { createBarkNotifications, loadBarkConfig } = require('../src/bark-push');
const { taskLabelFromPrompt } = require('../src/claude-notification-labels');
const { spawnSync } = require('node:child_process');

const config = { enabled: true, includeSessionLabel: true, includeClaudeTaskLabel: true,
  endpoint: 'https://example.test/push', deviceKey: 'fixtureKeyOnly123' };
const hook = (event, fields = {}) => ({ hook_event_name: event, session_id: 'window-one',
  cwd: '/example/projects/storefront', ...fields });
function fixture(t) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-label-test-'));
  t.after(() => fs.rmSync(stateDir, { recursive: true, force: true }));
  return stateDir;
}
async function drain(stateDir, settings = config) {
  const sent = [];
  const notifier = createBarkNotifications({ stateDir, config: settings, report: () => {},
    fetchImpl: async (_, options) => {
      sent.push(JSON.parse(options.body));
      return { ok: true, status: 200, json: async () => ({ code: 200 }) };
    } });
  try { await notifier.drain(); } finally { await notifier.close(); }
  return sent;
}
test('same-folder Claude windows show their own task and project, with stable distinct groups', async t => {
  const stateDir = fixture(t);
  for (const [session_id, prompt] of [['window-one', '修复购物车结算按钮'], ['window-two', '检查登录后的跳转逻辑']]) {
    recordClaudeHook(hook('UserPromptSubmit', { session_id, session_title: 'storefront', prompt }), { stateDir, config });
    recordClaudeHook(hook('Stop', { session_id }), { stateDir, config });
  }
  const sent = await drain(stateDir);
  assert.equal(sent.length, 2);
  assert.match(sent[0].body, /^修复购物车结算按钮\nstorefront · [a-f0-9]{8}$/);
  assert.match(sent[1].body, /^检查登录后的跳转逻辑\nstorefront · [a-f0-9]{8}$/);
  assert.notEqual(sent[0].group, sent[1].group);
  assert(sent.every(p => p.title === 'Claude · 本轮已回复'));
  assert(!JSON.stringify(sent).includes('/example/'));
});
test('queued replies retain their task; brief follow-ups and background wrappers preserve context', async t => {
  const stateDir = fixture(t);
  const prompts = ['修复购物车结算按钮', '继续', '<task-notification>PRIVATE BACKGROUND OUTPUT</task-notification>', '补充登录流程测试'];
  for (const [index, prompt] of prompts.entries()) {
    const prompt_id = `turn-${index}`;
    recordClaudeHook(hook('UserPromptSubmit', { prompt_id, prompt }), { stateDir, config });
    recordClaudeHook(hook('Stop', { prompt_id }), { stateDir, config });
  }
  const sent = await drain(stateDir);
  assert.equal(sent.length, 4);
  assert(sent.slice(0, 3).every(p => p.body.startsWith('修复购物车结算按钮\n')));
  assert(sent[3].body.startsWith('补充登录流程测试\n'));
  assert.equal(new Set(sent.map(p => p.group)).size, 1);
  assert(!JSON.stringify(sent).includes('PRIVATE'));
});
test('task sharing is separately opt-in and cannot be enabled when session labels are off', async t => {
  for (const settings of [{ ...config, includeClaudeTaskLabel: false }, { ...config, includeSessionLabel: false }]) {
    const stateDir = fixture(t);
    recordClaudeHook(hook('UserPromptSubmit', { prompt: 'PRIVATE PROMPT', session_title: 'Frontend' }), { stateDir, config: settings });
    recordClaudeHook(hook('Stop'), { stateDir, config: settings });
    const sent = await drain(stateDir, settings);
    assert(!JSON.stringify(sent).includes('PRIVATE'));
    const store = new NotificationStore(stateDir);
    try { assert.equal(store.db.prepare('SELECT count(*) AS n FROM claude_task_labels').get().n, 0); }
    finally { store.close(); }
  }
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json');
  fs.writeFileSync(file, JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey,
    includeSessionLabel: false, includeClaudeTaskLabel: true }), { mode: 0o600 });
  assert.equal(loadBarkConfig({ stateDir }).includeClaudeTaskLabel, false);
});
test('disabling task sharing before dispatch uses the queued non-task label', async t => {
  const stateDir = fixture(t);
  recordClaudeHook(hook('UserPromptSubmit', { prompt: 'PRIVATE TASK', session_title: 'Frontend' }), { stateDir, config });
  recordClaudeHook(hook('Stop'), { stateDir, config });
  const sent = await drain(stateDir, { ...config, includeClaudeTaskLabel: false });
  assert.match(sent[0].body, /^Frontend · storefront · [a-f0-9]{8}$/);
  assert(!JSON.stringify(sent).includes('PRIVATE'));
});
test('task titles exclude pasted blocks, code, URLs, full paths and common secret formats', async t => {
  const stateDir = fixture(t);
  const prompt = '检查 `/Users/private/projects/storefront` 的配置\n```sh\nPRIVATE COMMAND\n```\n<pasted_content id="1">PRIVATE PASTE</pasted_content id="1">';
  recordClaudeHook(hook('UserPromptSubmit', { prompt }), { stateDir, config });
  recordClaudeHook(hook('Stop', { last_assistant_message: 'PRIVATE ANSWER' }), { stateDir, config });
  const sent = await drain(stateDir);
  assert.match(sent[0].body, /^检查 storefront 的配置\n/);
  assert(!JSON.stringify(sent).match(/PRIVATE|\/Users\/|```/));
});
test('home-directory sessions lead with the task instead of the account name', async t => {
  const stateDir = fixture(t), cwd = os.homedir(), session_title = path.basename(cwd);
  recordClaudeHook(hook('UserPromptSubmit', { cwd, session_title, prompt: '整理本周的阅读笔记' }), { stateDir, config });
  recordClaudeHook(hook('Stop', { cwd }), { stateDir, config });
  const sent = await drain(stateDir);
  assert.match(sent[0].body, /^整理本周的阅读笔记 · [a-f0-9]{8}$/);
});
test('task excerpts are Unicode-bounded and redact common credentials and URLs before clipping', () => {
  assert.equal(taskLabelFromPrompt('检查 https://example.test/private-key 的连接'), '检查 [链接] 的连接');
  assert.equal(taskLabelFromPrompt('更新 token=private-token-value 后重试'), '更新 [已隐藏] 后重试');
  assert.equal(taskLabelFromPrompt('检查 sk-proj-secretValue12345 的配置'), '检查 [已隐藏] 的配置');
  assert.equal(taskLabelFromPrompt('🍎'.repeat(50)), '🍎'.repeat(32) + '…');
  assert.equal(taskLabelFromPrompt('```text\nPRIVATE\n```'), null);
  assert.equal(taskLabelFromPrompt('<system-reminder>PRIVATE'), null);
});
test('management preserves receiver settings and clears task excerpts from pending notices on opt-out', async t => {
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json');
  const receiver = { enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey,
    includeSessionLabel: true, icons: { claude: 'https://example.test/icon.png' } };
  fs.writeFileSync(file, JSON.stringify(receiver), { mode: 0o600 });
  const manage = choice => spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning',
    path.resolve(__dirname, '../../scripts/bark-notifications.cjs'), '--claude-task-labels', choice],
  { env: { ...process.env, CODEX_REMOTE_DEVICE_STATE_DIR: stateDir }, encoding: 'utf8' });
  assert.equal(manage('on').status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { ...receiver, includeClaudeTaskLabel: true });
  recordClaudeHook(hook('UserPromptSubmit', { prompt: 'PRIVATE TASK', session_title: 'Frontend' }), { stateDir });
  recordClaudeHook(hook('Stop'), { stateDir });
  assert.equal(manage('off').status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { ...receiver, includeClaudeTaskLabel: false });
  const store = new NotificationStore(stateDir);
  try {
    assert.equal(store.db.prepare('SELECT count(*) AS n FROM claude_task_labels').get().n, 0);
    assert(!JSON.stringify(store.db.prepare('SELECT payload FROM notices').all()).includes('PRIVATE'));
  } finally { store.close(); }
  // An old worker with stale settings can only see the redacted queued payload.
  const sent = await drain(stateDir, config);
  assert.match(sent[0].body, /^Frontend · storefront · [a-f0-9]{8}$/);
});
test('a running dispatcher applies task-label preference changes without restarting', async t => {
  const stateDir = fixture(t), file = path.join(stateDir, 'bark-config.json'), sent = [];
  const receiver = { enabled: true, serverUrl: 'https://example.test', deviceKey: config.deviceKey,
    includeSessionLabel: true, includeClaudeTaskLabel: false };
  const configure = enabled => fs.writeFileSync(file, JSON.stringify({ ...receiver, includeClaudeTaskLabel: enabled }), { mode: 0o600 });
  configure(false);
  const notifier = createBarkNotifications({ stateDir, report: () => {}, fetchImpl: async (_, options) => {
    sent.push(JSON.parse(options.body));
    return { ok: true, status: 200, json: async () => ({ code: 200 }) };
  } });
  try {
    configure(true);
    recordClaudeHook(hook('UserPromptSubmit', { prompt: '修复购物车结算按钮' }), { stateDir });
    recordClaudeHook(hook('Stop'), { stateDir });
    await notifier.drain();
    assert.match(sent[0].body, /^修复购物车结算按钮\nstorefront · [a-f0-9]{8}$/);
    recordClaudeHook(hook('UserPromptSubmit', { prompt: '检查登录后的跳转逻辑' }), { stateDir });
    recordClaudeHook(hook('Stop'), { stateDir });
    configure(false);
    await notifier.drain();
    assert.match(sent[1].body, /^storefront · [a-f0-9]{8}$/);
  } finally { await notifier.close(); }
});
