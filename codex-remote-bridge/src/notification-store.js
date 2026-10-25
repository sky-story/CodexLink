// One durable outbox shared by the Bridge and short-lived Claude hook processes.
// A claim is committed before HTTP dispatch: an uncertain send is never replayed.
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

class NotificationStore {
  constructor(stateDir, { now = () => Date.now() } = {}) {
    this.now = now;
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const filename = path.join(stateDir, 'notification-deliveries.sqlite');
    fs.closeSync(fs.openSync(filename, 'a', 0o600));
    fs.chmodSync(filename, 0o600);
    this.db = new DatabaseSync(filename);
    try {
      this.db.exec(`PRAGMA busy_timeout=3000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS notices (
          provider TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
          status TEXT NOT NULL, created_at INTEGER NOT NULL, payload TEXT,
          PRIMARY KEY(provider,id));
        CREATE TABLE IF NOT EXISTS claude_sessions (
          id TEXT PRIMARY KEY, run TEXT NOT NULL, label TEXT, updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS claude_task_labels (
          id TEXT PRIMARY KEY, label TEXT NOT NULL, updated_at INTEGER NOT NULL);`);
      this.migrateLegacy(stateDir);
      this.suppressClaudeBackgroundProgress();
    } catch (error) { this.db.close(); throw error; }
  }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = fn(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  migrateLegacy(stateDir) {
    this.transaction(() => {
      const file = path.join(stateDir, 'bark-deliveries.json');
      const entries = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
      if (!entries || typeof entries !== 'object' || Array.isArray(entries)) throw new Error('Invalid legacy ledger');
      const insert = this.db.prepare('INSERT OR IGNORE INTO notices VALUES (?,?,?,?,?,NULL)');
      for (const [id, row] of Object.entries(entries)) {
        if (!/^[a-f0-9]{64}$/.test(id) || !row || !Number.isFinite(row.at)) throw new Error('Invalid legacy ledger');
        insert.run('codex', id, String(row.kind || ''), ['accepted', 'rejected'].includes(row.status) ? row.status : 'unknown', row.at);
      }
      // Import on each process start: an older Bridge can still have appended
      // receipts between installing the Claude hooks and upgrading the service.
    });
  }
  suppressClaudeBackgroundProgress() {
    this.transaction(() => {
      // Already-running Claude sessions keep their pinned Hook runtime. Enforce
      // this policy in the shared outbox too, so their old writers become quiet
      // without changing runtime snapshots or interrupting the CLI.
      this.db.exec(`CREATE TRIGGER IF NOT EXISTS suppress_claude_background_progress
        BEFORE INSERT ON notices
        WHEN NEW.provider='claude' AND NEW.kind='background' AND NEW.status='pending'
        BEGIN SELECT RAISE(IGNORE); END;`);
      this.db.prepare(`UPDATE notices SET status='suppressed',payload=NULL
        WHERE provider='claude' AND kind='background' AND status='pending'`).run();
    });
  }
  enqueue({ provider, id, kind, presentation }) {
    if (!['codex', 'claude'].includes(provider) || !/^[a-f0-9]{64}$/.test(id)) throw new Error('Invalid notice identity');
    return this.db.prepare('INSERT OR IGNORE INTO notices VALUES (?,?,?,?,?,?)')
      .run(provider, id, kind, 'pending', this.now(), JSON.stringify(presentation)).changes > 0;
  }
  claim() {
    return this.transaction(() => {
      const row = this.db.prepare("SELECT * FROM notices WHERE status='pending' ORDER BY created_at,rowid LIMIT 1").get();
      if (!row) return null;
      this.db.prepare("UPDATE notices SET status='unknown' WHERE provider=? AND id=?").run(row.provider, row.id);
      return row;
    });
  }
  finish(row, status) {
    this.db.prepare('UPDATE notices SET status=?,payload=NULL WHERE provider=? AND id=?')
      .run(['accepted', 'rejected'].includes(status) ? status : 'unknown', row.provider, row.id);
  }
  clearClaudeTaskLabels() {
    this.transaction(() => {
      this.db.exec('DELETE FROM claude_task_labels');
      // Also remove task excerpts from unclaimed notices, including those an
      // already-running older dispatcher may pick up after this opt-out.
      for (const row of this.db.prepare("SELECT id,payload FROM notices WHERE provider='claude' AND status='pending'").all()) {
        const payload = JSON.parse(row.payload);
        if (!payload?.usesClaudeTaskLabel) continue;
        const { usesClaudeTaskLabel, fallbackBody, ...display } = payload;
        display.body = fallbackBody || 'Claude 本轮状态已更新，请在 Mac 查看。';
        this.db.prepare("UPDATE notices SET payload=? WHERE provider='claude' AND id=? AND status='pending'")
          .run(JSON.stringify(display), row.id);
      }
    });
  }
  prune() {
    const cutoff = this.now() - 7 * 86400000;
    // Never send stale pending notifications after a long outage.
    this.db.prepare('DELETE FROM notices WHERE created_at<?').run(cutoff);
    this.db.prepare('DELETE FROM claude_sessions WHERE updated_at<?').run(cutoff);
    this.db.prepare('DELETE FROM claude_task_labels WHERE updated_at<?').run(cutoff);
  }
  close() { this.db.close(); }
}
module.exports = { NotificationStore };
