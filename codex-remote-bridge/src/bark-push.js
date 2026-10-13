// Optional Bark notifications. Opt-in session labels never include message previews.
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { resolveCodexRemoteStateDir } = require('./daemon-state');
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
    return { enabled: true, reason: 'configured', endpoint: `${url.origin}/push`, deviceKey: config.deviceKey, includeSessionLabel: config.includeSessionLabel === true };
  } catch { return { enabled: false, reason: 'invalid_config' }; }
}
function cleanLabel(value) {
  if (typeof value !== 'string') return '';
  const text = value.replace(/[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim();
  const chars = Array.from(text);
  return chars.length > 40 ? chars.slice(0, 40).join('') + '…' : text;
}
function sessionPresentation(session) {
  if (!session || typeof session.threadId !== 'string' || !session.threadId) return null;
  // UUIDv7 prefixes share timestamps; hash the entire ID to distinguish nearby/same-name sessions.
  const shortId = createHash('sha256').update(session.threadId).digest('hex').slice(0, 8);
  const project = typeof session.cwd === 'string' ? path.basename(session.cwd.replace(/\/+$/, '')) : '';
  const name = cleanLabel(session.name) || cleanLabel(project) || '未命名会话';
  return { body: `${name} · ${shortId}`, group: `Codex · ${shortId}` };
}
async function sendBark(config, kind, { fetchImpl = fetch, session } = {}) {
  if (!config.enabled || !Object.hasOwn(BODIES, kind)) throw new Error('Bark 未配置或通知类型无效。');
  const presentation = config.includeSessionLabel ? sessionPresentation(session) : null;
  try {
    const response = await fetchImpl(config.endpoint, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ device_key: config.deviceKey, title: presentation ? TITLES[kind] : 'CodexLink', body: presentation?.body || BODIES[kind], group: presentation?.group || 'Codex Remote', isArchive: '0' }),
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
  let m; try { m = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return null; }
  const p = m?.params || {}, threadId = p.threadId;
  if (!threadId) return null;
  let kind, identity;
  if (m.method === 'turn/completed' && p.turn?.id && ['completed', 'failed', 'interrupted'].includes(p.turn.status)) {
    kind = p.turn.status; identity = ['turn', threadId, p.turn.id];
  } else if (m.id != null && ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/permissions/requestApproval', 'item/tool/requestUserInput'].includes(m.method)) {
    kind = m.method.endsWith('requestApproval') ? 'approval' : 'input';
    if (!p.turnId || !p.itemId) return null;
    identity = [kind, threadId, p.turnId, p.itemId, m.id];
  } else return null;
  return { kind, threadId, id: createHash('sha256').update(JSON.stringify(identity)).digest('hex') };
}
function createBarkNotifications({ stateDir = resolveCodexRemoteStateDir(), config = loadBarkConfig({ stateDir }), fetchImpl = fetch, readThread = async () => null, metadataTimeoutMs = 1500,
  report = status => console.log(`[codex-remote] bark: ${JSON.stringify(status)}`), now = () => Date.now() } = {}) {
  const stateFile = path.join(stateDir, 'bark-deliveries.json');
  let entries = {}, enabled = config.enabled, reason = config.reason;
  if (enabled) {
    try {
      if (fs.existsSync(stateFile)) {
        entries = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
        if (!entries || typeof entries !== 'object' || Array.isArray(entries)) throw new Error('invalid ledger');
      }
    } catch { enabled = false; reason = 'invalid_delivery_ledger'; }
  }
  const metadata = new Map();
  report({ enabled, reason, includeSessionLabel: config.includeSessionLabel === true });
  function persist() {
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const temp = `${stateFile}.${process.pid}.tmp`;
    fs.writeFileSync(temp, JSON.stringify(entries), { mode: 0o600 });
    fs.renameSync(temp, stateFile);
  }
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
    if (!notice || entries[notice.id]) return;
    try {
      // Write before dispatch; reconnect/crash must not replay uncertain deliveries.
      const cutoff = now() - 7 * 86400000;
      for (const [key, value] of Object.entries(entries)) if (value.at < cutoff) delete entries[key];
      entries[notice.id] = { at: now(), kind: notice.kind, status: 'unknown' };
      persist();
      const session = config.includeSessionLabel ? await sessionFor(notice.threadId) : undefined;
      const result = await sendBark(config, notice.kind, { fetchImpl, session });
      entries[notice.id].status = result.status;
      persist();
      report({ kind: notice.kind, ...result });
    } catch {
      enabled = false;
      report({ enabled: false, reason: 'delivery_state_write_failed' });
    }
  }
  return { handleOutbound };
}
module.exports = { loadBarkConfig, sendBark, eventNotice, createBarkNotifications, sessionPresentation };
