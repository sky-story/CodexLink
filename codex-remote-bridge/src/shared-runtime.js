// A client of the existing daemon, never a second execution owner.
const WebSocket = require('ws');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { ControlStore } = require('./control-store');
const { SessionController } = require('./session-controller');
const { createMacTerminal } = require('./mac-terminal');
const { buildClientHandshake } = require('./client-protocol');

function defaultEndpoint(env = process.env) {
  const home = env.CODEX_HOME || path.join(os.homedir(), '.codex');
  return `unix://${path.join(home, 'app-server-control', 'app-server-control.sock')}`;
}
function socketURL(endpoint) {
  if (endpoint.startsWith('unix://')) return `ws+unix://${endpoint.slice(7)}:/`;
  const url = new URL(endpoint);
  if (url.protocol !== 'wss:' && !(url.protocol === 'ws:' && ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname))) throw new Error('Codex endpoint must use a local Unix socket, loopback, or WSS');
  return endpoint;
}
// Full-history reads of long local threads exceed 32 MiB (measured 32.3 MiB). An
// oversized frame closes the whole daemon socket, so the phone loops forever between
// "loading" and "waiting for Codex". The socket is local; relay payloads are trimmed later.
const DAEMON_MAX_PAYLOAD_BYTES = 512 * 1024 * 1024;
const READ_METHODS = new Set(['model/list', 'thread/list', 'thread/loaded/list', 'thread/read', 'thread/turns/list', 'thread/items/list', 'thread/queue/list', 'thread/name/set', 'thread/unsubscribe', 'account/read', 'account/rateLimits/read', 'skills/list', 'collaborationMode/list', 'mcpServerStatus/list', 'plugin/list']);

async function readThreadWithLiveFallback(rpc, params) {
  try { return await rpc('thread/read', params); }
  catch (error) {
    // 0.162.1 can report an unavailable paginated history operation. Only use
    // the live object on this SAME daemon; never restore an unloaded history.
    const threadId = params.threadId || params.thread_id;
    if (error.code !== -32601 || error.message !== 'list_turns is not supported yet'
      || !(params.includeTurns || params.include_turns) || !threadId) throw error;
    let cursor = null;
    do {
      const page = await rpc('thread/loaded/list', { limit: 100, cursor });
      if (page.data.includes(threadId)) {
        const live = await rpc('thread/resume', { threadId });
        return { thread: live.thread };
      }
      cursor = page.nextCursor;
    } while (cursor);
    throw error;
  }
}

function createSharedRuntime({ endpoint = defaultEndpoint(), env = process.env, store: providedStore, discoveryInterval = 3000,
  reportConnection = message => console.warn(`[codex-remote] ${new Date().toISOString()} pid=${process.pid} ${message}`),
} = {}) {
  const listeners = {}; const pending = new Map(); const attached = new Set();
  const store = providedStore || new ControlStore(path.join(env.CODEX_REMOTE_STATE_DIR || env.CODEX_REMOTE_DEVICE_STATE_DIR || path.join(os.homedir(), '.codex-remote'), 'control.sqlite'));
  let socket, ready = false, stopped = false, reconnectTimer, discoveryTimer, attempts = 0, discovering = false;
  const emit = message => {
    if (!message.method?.startsWith('codex/event/')) {
      const seq = store.append(message);
      listeners.message?.(JSON.stringify({ ...message, remoteSequence: seq }));
    }
  };
  const rpc = (method, params) => new Promise((resolve, reject) => {
    if ((!ready && method !== 'initialize') || socket?.readyState !== WebSocket.OPEN) return reject(new Error('Codex daemon disconnected; request was not sent'));
    if (method === null) { socket.send(JSON.stringify(params), error => error ? reject(error) : resolve({})); return; }
    const id = `remote-internal-${randomUUID()}`;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Codex outcome unknown after timeout; not resent')); }, 30000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const controller = new SessionController({ rpc, store, emit });
  const macTerminal = createMacTerminal({ rpc, store, endpoint, env });
  async function attach(threadId) {
    if (attached.has(threadId)) return;
    const result = await rpc('thread/resume', { threadId, excludeTurns: true });
    attached.add(threadId);
    emit({ method: 'thread/started', params: { thread: result.thread } });
  }
  async function discover() {
    if (!ready || discovering) return;
    discovering = true;
    try {
      let cursor = null;
      do {
        const result = await rpc('thread/loaded/list', { limit: 100, cursor });
        for (const id of result.data) {
          if (attached.has(id)) continue;
          try { await attach(id); }
          catch (error) {
            // An unreadable/empty thread must not starve other live subscriptions.
            if (!ready) throw error;
            emit({ method: 'remote/status', params: { connected: true, detail: error.message } });
          }
        }
        cursor = result.nextCursor;
      } while (cursor && ready);
    } catch (error) { emit({ method: 'remote/status', params: { connected: ready, detail: error.message } }); }
    finally { discovering = false; }
  }
  function connect() {
    if (stopped) return;
    socket = new WebSocket(socketURL(endpoint), { maxPayload: DAEMON_MAX_PAYLOAD_BYTES,
      ...(env.CODEX_REMOTE_UPSTREAM_TOKEN ? { headers: { Authorization: `Bearer ${env.CODEX_REMOTE_UPSTREAM_TOKEN}` } } : {}) });
    socket.on('open', async () => {
      try {
        await rpc('initialize', { clientInfo: { name: 'codex_remote_ios_bridge', version: '0.1.0' }, capabilities: { experimentalApi: true } });
        socket.send(JSON.stringify({ method: 'initialized' }));
        ready = true;
        reportConnection('Codex daemon connection ready');
        attempts = 0; listeners.started?.({ mode: 'shared', launchDescription: endpoint });
        emit({ method: 'remote/status', params: { connected: true, sharedSession: true } });
        await discover();
        if (ready) discoveryTimer = setInterval(discover, discoveryInterval);
      } catch (error) {
        if (!stopped) reportConnection(`Codex daemon handshake failed (${error.code || error.name || 'error'})`);
        socket.close();
      }
    });
    socket.on('message', raw => {
      let message; try { message = JSON.parse(raw); } catch { return; }
      const waiter = pending.get(message.id);
      if (waiter && !message.method) {
        clearTimeout(waiter.timer); pending.delete(message.id);
        message.error ? waiter.reject(Object.assign(new Error(message.error.message), { code: message.error.code })) : waiter.resolve(message.result);
        return;
      }
      controller.observe(message);
      if (message.method === 'thread/closed') attached.delete(message.params.threadId);
      if (message.method) emit(message);
    });
    // Close drives recovery; logs contain transport metadata, never message content.
    socket.on('error', error => { if (!stopped) reportConnection(`Codex daemon socket error (${error.code || error.name || 'error'})`); });
    socket.on('close', code => {
      ready = false; attached.clear(); controller.approvals.clear(); clearInterval(discoveryTimer);
      for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(new Error('Codex disconnected; outcome unknown')); }
      pending.clear();
      if (!stopped) {
        reportConnection(`Codex daemon disconnected (close=${code}); reconnecting`);
        emit({ method: 'remote/status', params: { connected: false, detail: 'Waiting for the existing Codex daemon' } });
        reconnectTimer = setTimeout(connect, Math.min(1000 * 2 ** attempts++, 30000));
      } else if (!providedStore) {
        Promise.allSettled([...controller.chains.values()]).then(() => store.close());
      }
    });
  }
  async function request(message) {
    const { method, params = {} } = message;
    if (!method) {
      throw new Error('Approval and user-input replies require remote/control and a durable commandId');
    }
    if (method === 'initialize') return buildClientHandshake({ mode: 'shared', endpoint });
    if (method === 'initialized') return;
    if (method === 'remote/openOnMac') return macTerminal.open(params);
    if (method === 'remote/control') return controller.submit(params);
    if (method === 'remote/receipts') {
      const result = await readThreadWithLiveFallback(rpc, { threadId: params.threadId, includeTurns: true });
      for (const turn of result.thread.turns || []) for (const item of turn.items || []) {
        if (item.type === 'userMessage' && item.clientId && store.get(item.clientId)) controller.receipt(item.clientId, { status: 'observed', turnId: turn.id });
      }
      return { data: store.receipts(params.threadId) };
    }
    if (method === 'remote/sync') return { ...(params.snapshotOnly ? {} : store.replay(Number.isSafeInteger(params.after) ? params.after : 0)), connected: ready, approvals: [...controller.approvals.values()] };
    if (method === 'remote/queue') return rpc('thread/queue/list', { threadId: params.threadId });
    if (method === 'thread/read') return readThreadWithLiveFallback(rpc, params);
    if (method === 'remote/turnState') {
      if (typeof params.threadId !== 'string' || !params.threadId) throw Object.assign(new Error('threadId is required'), { code: -32602 });
      // The phone polls Turn status while a task runs. Full items made each poll megabytes
      // over the relay; read them locally and return only the Turn metadata.
      const { thread } = await readThreadWithLiveFallback(rpc, { threadId: params.threadId, includeTurns: true });
      return { thread: { id: thread.id, turns: (thread.turns || []).map(({ items, ...turn }) => turn) } };
    }
    if (method === 'thread/resume') {
      // Resume by ID rejoins a live runtime. Never replace its permissions/model with phone defaults.
      const result = await rpc(method, { threadId: params.threadId }); attached.add(params.threadId); return result;
    }
    if (method === 'thread/start') {
      // 0.162.1 defaults to paginated history, whose local store rejects list_turns.
      // Select the supported persisted format at creation, never migrate an existing thread.
      const result = await rpc(method, { cwd: params.cwd, approvalPolicy: 'on-request', approvalsReviewer: 'user', sandbox: 'workspace-write', historyMode: 'legacy', ...(params.model ? { model: params.model } : {}) });
      // thread/start already subscribes this connection. Resuming before its first
      // user message has no rollout to read and can block discovery of other threads.
      attached.add(result.thread.id);
      return result;
    }
    if (['turn/start', 'turn/steer', 'turn/interrupt'].includes(method)) throw Object.assign(new Error('Use remote/control with a stable commandId and an explicit Queue, Steer or Interrupt action'), { code: -32602 });
    if (!READ_METHODS.has(method)) throw Object.assign(new Error(`Method is outside the shared-session MVP: ${method}`), { code: -32601 });
    return rpc(method, params);
  }
  // Listeners are installed synchronously by the bridge before the connection opens.
  queueMicrotask(connect);
  return {
    mode: 'shared', describe: () => endpoint,
    send(raw) {
      let message; try { message = JSON.parse(raw); } catch { return; }
      request(message).then(result => {
        if (message.id != null && message.method) listeners.message?.(JSON.stringify({ id: message.id, result }));
      }).catch(error => {
        if (message.id != null) listeners.message?.(JSON.stringify({ id: message.id, error: { code: error.code || -32000, message: error.message } }));
      });
    },
    onMessage(fn) { listeners.message = fn; }, onStarted(fn) { listeners.started = fn; },
    onError(fn) { listeners.error = fn; }, onClose(fn) { listeners.close = fn; },
    shutdown() { stopped = true; clearTimeout(reconnectTimer); clearInterval(discoveryTimer); socket?.close(); },
  };
}
module.exports = { createSharedRuntime, defaultEndpoint, socketURL, readThreadWithLiveFallback };
