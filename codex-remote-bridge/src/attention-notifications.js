// Native background alerts for approval, input and important errors; no command contents in APNs.
const { createHash } = require('node:crypto');
const path = require('node:path');
function createAttentionNotifications({ pushServiceClient }) {
  const titles = new Map(); const delivered = new Set();
  async function handleOutbound(raw) {
    const message = typeof raw === 'string' ? JSON.parse(raw) : raw;
    const p = message.params || {}; const thread = p.thread;
    if (thread?.id) titles.set(thread.id, [thread.cwd ? path.basename(thread.cwd) : '', thread.name || 'Codex'].filter(Boolean).join(' · '));
    const threadId = p.threadId || thread?.id;
    if (!threadId || !pushServiceClient?.hasConfiguredBaseUrl) return;
    let result, body;
    if (message.method?.endsWith('requestApproval')) { result = 'approval'; body = 'Codex needs your approval. Open the app to review the exact operation.'; }
    else if (message.method?.endsWith('requestUserInput')) { result = 'input'; body = 'Codex needs your input.'; }
    else if (message.method === 'error' && p.willRetry !== true) { result = 'error'; body = 'Codex reported an error. Open the session for details.'; }
    else return;
    const key = createHash('sha256').update(JSON.stringify([threadId, p.turnId, p.itemId, message.id, result])).digest('hex');
    if (delivered.has(key)) return;
    delivered.add(key);
    if (delivered.size > 1000) delivered.delete(delivered.values().next().value);
    try { await pushServiceClient.notifyCompletion({ threadId, turnId: p.turnId || '', result, title: titles.get(threadId) || 'Codex Remote', body, dedupeKey: `attention-${key}` }); }
    catch { delivered.delete(key); }
  }
  return { handleOutbound };
}
module.exports = { createAttentionNotifications };
