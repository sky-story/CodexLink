// Local channel state. Only the paired-phone router can enqueue messages/verdicts;
// MCP tools expose replies, never a tool that can approve another tool call.
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { resolveCodexRemoteStateDir } = require('./daemon-state');

const LEASE_MS = 15000;
const APPROVAL_MS = 5 * 60000;
const error = message => Object.assign(new Error(message), { code: -32602 });
function identifier(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,100}$/.test(value)) throw error('Invalid identifier');
  return value;
}
function text(value, limit = 32768) {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit) throw error('Text is empty or too long');
  return value;
}
function clipped(value, limit = 8000) {
  if (typeof value !== 'string') return '';
  return Array.from(value).slice(0, limit).join('') + (Array.from(value).length > limit ? '\n[内容过长，已截断；请在 Mac 查看全文]' : '');
}

class ClaudeChannelStore {
  constructor({ stateDir = resolveCodexRemoteStateDir(), now = () => Date.now() } = {}) {
    this.now = now;
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const filename = path.join(stateDir, 'claude-channels.sqlite');
    fs.closeSync(fs.openSync(filename, 'a', 0o600)); fs.chmodSync(filename, 0o600);
    this.db = new DatabaseSync(filename);
    try {
      this.db.exec(`PRAGMA busy_timeout=3000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, generation TEXT NOT NULL, name TEXT NOT NULL, cwd TEXT NOT NULL,
        phase TEXT NOT NULL, heartbeat INTEGER NOT NULL, updated_at INTEGER NOT NULL, verified INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL,
        role TEXT NOT NULL, text TEXT NOT NULL, source TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id,seq);
      CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, generation TEXT NOT NULL, action TEXT NOT NULL,
        payload TEXT NOT NULL, status TEXT NOT NULL, detail TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS commands_session ON commands(session_id,created_at);
      CREATE TABLE IF NOT EXISTS permissions (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, generation TEXT NOT NULL, relay_id TEXT NOT NULL,
        tool TEXT NOT NULL, description TEXT NOT NULL, preview TEXT NOT NULL, status TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS permissions_session ON permissions(session_id,status);`);
    } catch (e) { this.db.close(); throw e; }
  }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = fn(); this.db.exec('COMMIT'); return value; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  get(id) { return this.db.prepare('SELECT * FROM sessions WHERE id=?').get(identifier(id)); }
  requireSession(id, generation, online = false) {
    const s = this.get(id);
    if (!s || (generation && s.generation !== generation)) throw error('Claude session changed; refresh before sending');
    if (online && (s.phase === 'closed' || s.heartbeat <= this.now() - LEASE_MS)) throw error('Claude session is offline; open it on Mac');
    return s;
  }
  register({ id, generation, name, cwd }) {
    identifier(id); identifier(generation); text(cwd, 4096);
    return this.transaction(() => {
      const old = this.get(id);
      if (old && old.phase !== 'closed' && old.heartbeat > this.now() - LEASE_MS) throw error('This Claude session is already connected');
      this.invalidate(id, 'Session reopened; previous pending operations were not resent');
      this.db.prepare(`INSERT INTO sessions VALUES (?,?,?,?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET
        generation=excluded.generation,name=excluded.name,cwd=excluded.cwd,phase=excluded.phase,
        heartbeat=excluded.heartbeat,updated_at=excluded.updated_at,verified=0`)
        .run(id, generation, clipped(name || path.basename(cwd), 100) || 'Claude', cwd, 'starting', 0, this.now());
    });
  }
  heartbeat(id, generation) {
    this.requireSession(id, generation);
    this.db.prepare("UPDATE sessions SET heartbeat=?,phase=CASE WHEN phase='starting' THEN 'idle' ELSE phase END WHERE id=? AND generation=? AND phase!='closed'")
      .run(this.now(), id, generation);
  }
  setPhase(id, phase) { this.db.prepare('UPDATE sessions SET phase=?,updated_at=? WHERE id=?').run(phase, this.now(), id); }
  invalidate(id, detail) {
    this.db.prepare("UPDATE commands SET status='failed',detail=?,updated_at=? WHERE session_id=? AND status='queued'").run(detail, this.now(), id);
    this.db.prepare("UPDATE permissions SET status='closed' WHERE session_id=? AND status IN ('pending','submitted')").run(id);
  }
  closeSession(id, generation) {
    return this.transaction(() => { this.requireSession(id, generation); this.invalidate(id, 'Claude session closed'); this.setPhase(id, 'closed'); });
  }
  sessionView(s) {
    return { id: s.id, generation: s.generation, name: s.name, project: path.basename(s.cwd), phase: s.phase,
      online: s.phase !== 'closed' && s.heartbeat > this.now() - LEASE_MS, verified: Boolean(s.verified), updatedAt: s.updated_at };
  }
  list() { return { data: this.db.prepare('SELECT * FROM sessions ORDER BY updated_at DESC LIMIT 100').all().map(s => this.sessionView(s)) }; }
  receipt(row) { return { id: row.id, sessionId: row.session_id, action: row.action, status: row.status, detail: row.detail, updatedAt: row.updated_at }; }
  snapshot(id, before) {
    const session = this.requireSession(id);
    if (before !== undefined && (!Number.isSafeInteger(before) || before < 1)) throw error('Invalid history cursor');
    const messages = this.db.prepare(`SELECT seq,id,role,text,source,created_at AS createdAt FROM messages
      WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT 41`).all(id, before || Number.MAX_SAFE_INTEGER);
    const more = messages.length > 40; if (more) messages.pop(); messages.reverse();
    const permissions = this.db.prepare(`SELECT id,tool,description,preview,status,expires_at AS expiresAt FROM permissions
      WHERE session_id=? AND generation=? AND status IN ('pending','submitted') AND expires_at>? ORDER BY created_at LIMIT 20`).all(id, session.generation, this.now());
    const receipts = this.db.prepare('SELECT * FROM commands WHERE session_id=? ORDER BY created_at DESC LIMIT 60').all(id).map(r => this.receipt(r));
    return { session: this.sessionView(session), messages, permissions, receipts, nextBefore: more ? messages[0].seq : null };
  }
  insertMessage(id, session, role, body, source) {
    this.db.prepare('INSERT OR IGNORE INTO messages(id,session_id,role,text,source,created_at) VALUES (?,?,?,?,?,?)').run(id, session, role, body, source, this.now());
  }
  isChannelEcho(id, generation, prompt) {
    // UserPromptSubmit can also fire for channel input. Suppress only an exact
    // echo of our own dispatched message; identical text typed on Mac is distinct.
    const match = /^<channel source="codexlink" message_id="([a-zA-Z0-9_-]{1,100})">\n([\s\S]*)\n<\/channel>$/.exec(prompt);
    if (!match) return false;
    const row = this.db.prepare("SELECT payload FROM commands WHERE id=? AND session_id=? AND generation=? AND action='message' AND status IN ('sent','unknown','replied')").get(match[1], id, generation);
    return Boolean(row && JSON.parse(row.payload).text === match[2]);
  }
  submit({ sessionId, generation, commandId, action, message, permissionId, behavior }) {
    identifier(commandId); identifier(generation);
    if (!['message', 'permission'].includes(action)) throw error('Unsupported Claude action');
    const payload = action === 'message' ? { text: text(message) } : { permissionId: identifier(permissionId), behavior };
    if (action === 'permission' && !['allow', 'deny'].includes(behavior)) throw error('Only allow once or deny is supported');
    const encoded = JSON.stringify(payload);
    return this.transaction(() => {
      const existing = this.db.prepare('SELECT * FROM commands WHERE id=?').get(commandId);
      if (existing) {
        if (existing.session_id !== sessionId || existing.generation !== generation || existing.action !== action || existing.payload !== encoded) throw error('Command ID was reused with different content');
        return this.receipt(existing);
      }
      this.requireSession(sessionId, generation, true);
      if (action === 'permission') {
        const request = this.db.prepare('SELECT * FROM permissions WHERE id=?').get(permissionId);
        if (!request || request.session_id !== sessionId || request.generation !== generation || request.status !== 'pending' || request.expires_at <= this.now()) throw error('Approval expired or already answered; refresh the session');
        if (behavior === 'allow' && /code points elided|\[内容过长|\(value unserializable\)/.test(request.preview)) throw error('Approval details are incomplete; review on Mac');
        this.db.prepare("UPDATE permissions SET status='submitted' WHERE id=?").run(permissionId);
      }
      this.db.prepare('INSERT INTO commands VALUES (?,?,?,?,?,?,?,?,?)').run(commandId, sessionId, generation, action, encoded, 'queued', null, this.now(), this.now());
      if (action === 'message') this.insertMessage(commandId, sessionId, 'user', payload.text, 'phone');
      return this.receipt(this.db.prepare('SELECT * FROM commands WHERE id=?').get(commandId));
    });
  }
  command(id, sessionId) {
    const row = this.db.prepare('SELECT * FROM commands WHERE id=? AND session_id=?').get(identifier(id), identifier(sessionId));
    return row ? this.receipt(row) : null;
  }
  claim(id, generation) {
    return this.transaction(() => {
      this.requireSession(id, generation, true);
      const row = this.db.prepare("SELECT * FROM commands WHERE session_id=? AND generation=? AND status='queued' ORDER BY created_at,rowid LIMIT 1").get(id, generation);
      if (!row) return null;
      if (this.now() - row.created_at > 2 * 60000) { this.finish(row.id, 'failed', 'Message expired before dispatch'); return { skipped: true }; }
      const payload = JSON.parse(row.payload);
      if (row.action === 'permission') {
        const permission = this.db.prepare('SELECT * FROM permissions WHERE id=?').get(payload.permissionId);
        if (!permission || permission.status !== 'submitted' || permission.expires_at <= this.now()) {
          this.finish(row.id, 'failed', 'Approval is no longer pending'); return { skipped: true };
        }
        payload.relayId = permission.relay_id;
      }
      // Durable before write. A process crash never replays a possibly-sent verdict/message.
      this.finish(row.id, 'unknown', 'Dispatch started; processing is not yet confirmed');
      return { ...row, payload };
    });
  }
  finish(id, status, detail = null) {
    this.db.prepare("UPDATE commands SET status=?,detail=?,updated_at=? WHERE id=? AND status!='replied'").run(status, detail, this.now(), id);
  }
  reply(id, generation, messageId, body) {
    text(body);
    return this.transaction(() => {
      this.requireSession(id, generation);
      const command = this.db.prepare("SELECT * FROM commands WHERE id=? AND session_id=? AND generation=? AND action='message'").get(identifier(messageId), id, generation);
      if (!command || !['sent', 'unknown', 'replied'].includes(command.status)) throw error('Reply does not match a dispatched message in this session');
      if (command.status === 'replied') {
        const old = this.db.prepare('SELECT text FROM messages WHERE id=?').get(`reply-${messageId}`);
        if (old?.text !== body) throw error('A reply already exists for this message');
        return;
      }
      this.insertMessage(`reply-${messageId}`, id, 'assistant', body, 'channel');
      this.finish(messageId, 'replied');
      this.db.prepare('UPDATE sessions SET verified=1,updated_at=? WHERE id=?').run(this.now(), id);
    });
  }
  permission(id, generation, params) {
    if (!/^[a-km-z]{5}$/.test(params?.request_id || '')) throw error('Invalid Claude permission request');
    text(params.tool_name, 256);
    return this.transaction(() => {
      this.requireSession(id, generation);
      const existing = this.db.prepare("SELECT * FROM permissions WHERE session_id=? AND generation=? AND relay_id=? AND status IN ('pending','submitted') AND expires_at>?").get(id, generation, params.request_id, this.now());
      if (existing) {
        if (existing.tool !== params.tool_name || existing.preview !== clipped(params.input_preview)) {
          this.db.prepare("UPDATE permissions SET status='closed' WHERE id=?").run(existing.id);
          return null; // Persist the invalidation; never approve an ambiguous ID.
        }
        return existing.id;
      }
      const permissionId = randomUUID();
      this.db.prepare('INSERT INTO permissions VALUES (?,?,?,?,?,?,?,?,?,?)').run(permissionId, id, generation, params.request_id, params.tool_name,
        clipped(params.description), clipped(params.input_preview), 'pending', this.now(), this.now() + APPROVAL_MS);
      this.setPhase(id, 'approval');
      return permissionId;
    });
  }
  hook(id, generation, input) {
    if (input?.session_id !== id || input.agent_id) return;
    return this.transaction(() => {
      const session = this.requireSession(id, generation);
      if (session.phase === 'closed') return;
      const event = input.hook_event_name;
      if (event === 'UserPromptSubmit') {
        if (typeof input.prompt === 'string' && input.prompt.trim() && !this.isChannelEcho(id, generation, input.prompt)) {
          const key = createHash('sha256').update(`${generation}:${input.prompt_id || randomUUID()}`).digest('hex');
          this.insertMessage(`mac-${key}`, id, 'user', clipped(input.prompt), 'mac');
        }
        this.setPhase(id, 'working');
      } else if (event === 'Stop') {
        const body = clipped(input.last_assistant_message);
        const last = this.db.prepare("SELECT role,text FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 1").get(id);
        if (body.trim() && !(last?.role === 'assistant' && last.text === body)) this.insertMessage(randomUUID(), id, 'assistant', body, 'mac');
        this.setPhase(id, 'idle');
      } else if (event === 'StopFailure') this.setPhase(id, 'failed');
      else if (event === 'SessionEnd') { this.invalidate(id, 'Claude session ended'); this.setPhase(id, 'closed'); }
      else if (['PostToolUse', 'PostToolUseFailure'].includes(event)) this.setPhase(id, 'working');
      else return;
      // There is no permission-resolved notification in Channels. Invalidate
      // conservatively when the CLI advances; Claude itself arbitrates first reply.
      this.db.prepare("UPDATE permissions SET status='closed' WHERE session_id=? AND generation=? AND status IN ('pending','submitted')").run(id, generation);
    });
  }
  close() { this.db.close(); }
}
module.exports = { ClaudeChannelStore, LEASE_MS, APPROVAL_MS, identifier, clipped };
