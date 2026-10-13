// Durable command receipts. Written BEFORE dispatch; uncertain operations are never resent.
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
class ControlStore {
  constructor(filename) {
    if (filename !== ':memory:') {
      fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
      // Hold a separate SQLite writer lock for the controller lifetime. The OS releases
      // it on process death, avoiding stale PID files and races during crash recovery.
      const ownerFile = `${filename}.owner`;
      fs.closeSync(fs.openSync(ownerFile, 'a', 0o600));
      this.owner = new DatabaseSync(ownerFile);
      try { this.owner.exec('PRAGMA busy_timeout=0; CREATE TABLE IF NOT EXISTS owner(id INTEGER); BEGIN EXCLUSIVE;'); }
      catch { this.owner.close(); throw new Error('A session controller is already running for this state directory'); }
      fs.closeSync(fs.openSync(filename, 'a', 0o600));
      fs.chmodSync(filename, 0o600);
    }
    this.db = new DatabaseSync(filename);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY, hash TEXT NOT NULL, thread TEXT NOT NULL, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL);`);
    for (const row of this.db.prepare('SELECT id,value FROM commands').all()) {
      const value = JSON.parse(row.value);
      if (value.status === 'received') this.update(row.id, { status: 'unknown', detail: 'Bridge stopped before the upstream outcome was recorded. Not automatically resent.' });
    }
  }
  begin(command) {
    const hash = createHash('sha256').update(JSON.stringify(canonical(command))).digest('hex');
    const old = this.db.prepare('SELECT hash,value FROM commands WHERE id=?').get(command.commandId);
    if (old) {
      if (old.hash !== hash) throw new Error('commandId was already used for different input');
      return { fresh: false, receipt: JSON.parse(old.value) };
    }
    const receipt = { commandId: command.commandId, threadId: command.threadId, action: command.action, status: 'received', createdAt: new Date().toISOString() };
    this.db.prepare('INSERT INTO commands VALUES(?,?,?,?)').run(command.commandId, hash, command.threadId, JSON.stringify(receipt));
    return { fresh: true, receipt };
  }
  get(id) { const row = this.db.prepare('SELECT value FROM commands WHERE id=?').get(id); return row && JSON.parse(row.value); }
  update(id, changes) {
    const old = this.get(id); if (!old) return;
    const next = { ...old, ...changes, updatedAt: new Date().toISOString() };
    this.db.prepare('UPDATE commands SET value=? WHERE id=?').run(JSON.stringify(next), id); return next;
  }
  receipts(thread) { return this.db.prepare('SELECT value FROM commands WHERE thread=? ORDER BY rowid DESC LIMIT 100').all(thread).map(r => JSON.parse(r.value)); }
  append(event) {
    const result = this.db.prepare('INSERT INTO events(value) VALUES(?)').run(JSON.stringify(event));
    const seq = Number(result.lastInsertRowid);
    if (seq % 256 === 0) this.db.prepare('DELETE FROM events WHERE seq < ?').run(seq - 10000);
    return seq;
  }
  replay(after = 0) {
    const earliest = this.db.prepare('SELECT min(seq) AS seq FROM events').get().seq || 0;
    const latest = this.db.prepare('SELECT max(seq) AS seq FROM events').get().seq || 0;
    return { earliest, latest, snapshotRequired: after < earliest - 1 || after > latest,
      events: this.db.prepare('SELECT seq,value FROM events WHERE seq>? ORDER BY seq LIMIT 1000').all(after).map(r => ({ seq: r.seq, event: JSON.parse(r.value) })) };
  }
  close() { this.db.close(); this.owner?.close(); }
}
module.exports = { ControlStore };
