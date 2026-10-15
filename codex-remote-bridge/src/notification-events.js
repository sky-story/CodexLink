const { createHash } = require('node:crypto');
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

function codexNotice(raw) {
  let message; try { message = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return null; }
  const p = message?.params || {}, threadId = p.threadId;
  if (typeof threadId !== 'string' || !threadId) return null;
  let kind, identity;
  if (message.method === 'turn/completed' && p.turn?.id && ['completed', 'failed', 'interrupted'].includes(p.turn.status)) {
    kind = p.turn.status; identity = ['turn', threadId, p.turn.id];
  } else if (message.id != null && ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/permissions/requestApproval', 'item/tool/requestUserInput'].includes(message.method)) {
    kind = message.method.endsWith('requestApproval') ? 'approval' : 'input';
    if (!p.turnId || !p.itemId) return null;
    identity = [kind, threadId, p.turnId, p.itemId, message.id];
  } else return null;
  // Preserve the old ID so upgrading doesn't resend already-delivered Codex notices.
  return { provider: 'codex', kind, threadId, id: hash(identity) };
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
module.exports = { codexNotice, hash, canonical };
