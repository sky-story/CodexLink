// Optional Bark notifications. Opt-in session labels never include message previews.
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { resolveCodexRemoteStateDir } = require('./daemon-state');
const { NotificationStore } = require('./notification-store');
const { codexNotice } = require('./notification-events');
// Public artwork only. Pin CodexLink to a published revision; Claude uses the
// artwork URL from Anthropic's official App Store listing. Bark caches by URL.
const DEFAULT_BARK_ICONS = Object.freeze({
  codex: 'https://cdn.jsdelivr.net/gh/sky-story/CodexLink@dfc98b63cfde02d7071f54e5f48c886f8d6db4c9/CodexMobile/CodexMobile/Assets.xcassets/AppLogo.imageset/CodexRemote-iOS-Default-1024x1024.png',
  claude: 'https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/51/61/43/51614377-8976-4277-5f5e-90c614b04913/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg',
});
const BODIES = Object.freeze({
  completed: 'Codex 任务已完成，请打开 CodexLink 查看。',
  failed: 'Codex 任务执行失败，请打开 CodexLink 查看。',
  interrupted: 'Codex 当前任务已中断。',
  approval: 'Codex 有一项操作等待审批，请打开 CodexLink 审核。',
  input: 'Codex 需要你的补充信息，请打开 CodexLink 查看。',
  test: 'CodexLink 锁屏通知测试。收到此通知后，请告诉我。',
});
const TITLES = Object.freeze({
  completed: 'Codex · 任务已完成',
  failed: 'Codex · 任务失败',
  interrupted: 'Codex · 任务已中断',
  approval: 'Codex · 等待审批',
  input: 'Codex · 需要补充信息',
  test: 'Codex · 通知测试',
});
const CLAUDE_BODIES = Object.freeze({
  test: 'Claude 锁屏通知测试。请检查通知图标是否显示 Claude Logo。',
  response_ready: 'Claude 本轮已回复，请在 Mac 查看。',
  background: 'Claude 本轮已回复，仍有后台任务或计划任务，请在 Mac 查看。',
  failed: 'Claude 遇到 API 错误，请在 Mac 查看。',
  approval: 'Claude 有操作等待审批，请在 Mac 审核。',
  input: 'Claude 需要你的补充信息，请在 Mac 查看。',
});
const CLAUDE_TITLES = Object.freeze({
  test: 'Claude · 通知测试',
  response_ready: 'Claude · 本轮已回复', background: 'Claude · 后台仍有任务',
  failed: 'Claude · API 错误', approval: 'Claude · 等待审批', input: 'Claude · 需要补充信息',
});
function normalizeIconURL(value) {
  if (typeof value !== 'string' || value.length > 2048 || /[\s\x00-\x1f\x7f]/.test(value)) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' && !url.username && !url.password && !url.hash) return url.href;
  } catch { /* Invalid optional artwork must not disable notifications. */ }
  return undefined;
}
function loadBarkConfig({ stateDir = resolveCodexRemoteStateDir() } = {}) {
  const file = path.join(stateDir, 'bark-config.json');
  try {
    if (!fs.existsSync(file)) return { enabled: false, reason: 'not_configured' };
    if (fs.statSync(file).mode & 0o077) return { enabled: false, reason: 'config_permissions_must_be_600' };
    const config = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (config?.enabled !== true) return { enabled: false, reason: 'disabled' };
    const url = new URL(config.serverUrl);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
      || url.pathname !== '/' || !/^[A-Za-z0-9_-]{8,200}$/.test(config.deviceKey || '')) {
      return { enabled: false, reason: 'invalid_config' };
    }
    const icons = {};
    for (const provider of ['codex', 'claude']) {
      const icon = normalizeIconURL(config.icons?.[provider]);
      if (icon) icons[provider] = icon;
    }
    return { enabled: true, reason: 'configured', endpoint: `${url.origin}/push`, deviceKey: config.deviceKey,
      includeSessionLabel: config.includeSessionLabel === true, icons };
  } catch { return { enabled: false, reason: 'invalid_config' }; }
}
function cleanLabel(value) {
  if (typeof value !== 'string') return '';
  const text = value.replace(/[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim();
  const chars = Array.from(text);
  return chars.length > 40 ? chars.slice(0, 40).join('') + '…' : text;
}
function sessionPresentation(session, provider = 'codex') {
  if (!session || (!session.sessionKey && (typeof session.threadId !== 'string' || !session.threadId))) return null;
  // UUIDv7 prefixes share timestamps; hash the entire ID to distinguish nearby/same-name sessions.
  const shortId = (session.sessionKey || createHash('sha256').update(session.threadId).digest('hex')).slice(0, 8);
  const project = typeof session.cwd === 'string' ? path.basename(session.cwd.replace(/\/+$/, '')) : '';
  const name = cleanLabel(session.name) || cleanLabel(project) || '未命名会话';
  return { body: `${name} · ${shortId}`, group: `${provider === 'claude' ? 'Claude' : 'Codex'} · ${shortId}` };
}
function notificationPresentation(config, kind, { provider = 'codex', session } = {}) {
  const bodies = provider === 'claude' ? CLAUDE_BODIES : provider === 'codex' ? BODIES : {};
  const titles = provider === 'claude' ? CLAUDE_TITLES : TITLES;
  if (!Object.hasOwn(bodies, kind)) throw new Error('通知类型无效。');
  const label = config.includeSessionLabel ? sessionPresentation(session, provider) : null;
  return { title: kind === 'test' || label || provider === 'claude' ? titles[kind] : 'CodexLink',
    body: label?.body || bodies[kind], group: label?.group || (provider === 'claude' ? 'Claude' : 'Codex Remote') };
}
async function sendBark(config, kind, { fetchImpl = fetch, session, provider = 'codex', presentation } = {}) {
  if (!config.enabled) throw new Error('Bark 未配置。');
  const display = presentation || notificationPresentation(config, kind, { provider, session });
  // Select by the queued event's provider, not the process draining the shared
  // outbox or a stored presentation. This also applies updated icons to old rows.
  const icon = normalizeIconURL(config.icons?.[provider]);
  try {
    const response = await fetchImpl(config.endpoint, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ device_key: config.deviceKey, title: display.title, body: display.body, group: display.group, isArchive: '0', ...(icon ? { icon } : {}) }),
    });
    if (!response.ok) return { status: 'rejected', httpStatus: response.status };
    const body = await response.json();
    return body?.code === 200 ? { status: 'accepted', httpStatus: response.status } : { status: 'rejected', httpStatus: response.status };
  } catch {
    // Never log provider text, URL, request body or transport errors (may contain the device key).
    return { status: 'unknown', detail: 'Bark 请求结果不确定；未自动重发。' };
  }
}
function eventNotice(raw) {
  return codexNotice(raw);
}
function createBarkNotifications({ stateDir = resolveCodexRemoteStateDir(), config = loadBarkConfig({ stateDir }), fetchImpl = fetch, readThread = async () => null, metadataTimeoutMs = 1500,
  report = status => console.log(`[codex-remote] bark: ${JSON.stringify(status)}`), now = () => Date.now() } = {}) {
  let store, timer, draining, enabled = config.enabled, reason = config.reason;
  if (enabled) {
    try { store = new NotificationStore(stateDir, { now }); store.prune(); }
    catch { enabled = false; reason = 'invalid_delivery_ledger'; }
  }
  const metadata = new Map();
  report({ enabled, reason, includeSessionLabel: config.includeSessionLabel === true });
  function remember(raw) {
    let m; try { m = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return; }
    const p = m?.params || {};
    if (m?.method === 'thread/started' && typeof p.thread?.id === 'string') {
      metadata.set(p.thread.id, { name: p.thread.name, cwd: p.thread.cwd });
    } else if (m?.method === 'thread/name/updated' && typeof p.threadId === 'string') {
      metadata.set(p.threadId, { ...metadata.get(p.threadId), name: p.threadName ?? p.name ?? null });
    }
    if (metadata.size > 2000) metadata.delete(metadata.keys().next().value);
  }
  async function sessionFor(threadId) {
    let timer;
    try {
      const thread = await Promise.race([
        Promise.resolve().then(() => readThread(threadId)),
        new Promise(resolve => { timer = setTimeout(() => resolve(null), metadataTimeoutMs); }),
      ]);
      if (thread?.id === threadId) metadata.set(threadId, { name: thread.name, cwd: thread.cwd });
    } catch { /* A missing metadata response must never prevent the notification. */ }
    finally { clearTimeout(timer); }
    return { threadId, ...metadata.get(threadId) };
  }
  async function handleOutbound(raw) {
    if (!enabled) return;
    if (config.includeSessionLabel) remember(raw);
    const notice = eventNotice(raw);
    if (!notice) return;
    try {
      const session = config.includeSessionLabel ? await sessionFor(notice.threadId) : undefined;
      store.enqueue({ ...notice, presentation: notificationPresentation(config, notice.kind, { session }) });
      await drain();
    } catch {
      enabled = false;
      report({ enabled: false, reason: 'delivery_state_write_failed' });
    }
  }
  function drain() {
    if (!enabled) return Promise.resolve();
    if (draining) return draining;
    draining = (async () => {
      let row;
      while (enabled && (row = store.claim())) {
        // An opt-out made while a notice was queued also applies at dispatch.
        const presentation = config.includeSessionLabel ? JSON.parse(row.payload) : notificationPresentation(config, row.kind, { provider: row.provider });
        const result = await sendBark(config, row.kind, { fetchImpl, provider: row.provider, presentation });
        store.finish(row, result.status);
        report({ provider: row.provider, kind: row.kind, ...result });
      }
    })().catch(() => {
      enabled = false;
      report({ enabled: false, reason: 'delivery_state_write_failed' });
    }).finally(() => { draining = null; });
    return draining;
  }
  function start() {
    if (!enabled || timer) return;
    void drain();
    timer = setInterval(() => { void drain(); }, 5000);
    timer.unref();
  }
  async function close() { clearInterval(timer); await draining; store?.close(); }
  return { handleOutbound, drain, start, close };
}
module.exports = { loadBarkConfig, sendBark, eventNotice, createBarkNotifications, sessionPresentation, notificationPresentation, cleanLabel, normalizeIconURL, DEFAULT_BARK_ICONS };
