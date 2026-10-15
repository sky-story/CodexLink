const { ClaudeChannelStore } = require('./claude-channel-store');

// Called only after the Bridge authenticates/decrypts the paired phone envelope.
// No public HTTP listener and no Claude requests forwarded to the Codex daemon.
function createClaudeChannelRouter(options = {}) {
  let store;
  return {
    handle(raw, send) {
      let message; try { message = JSON.parse(raw); } catch { return false; }
      if (typeof message?.method !== 'string' || !message.method.startsWith('claude/')) return false;
      if (message.id == null) return true;
      try {
        if (Buffer.byteLength(raw) > 65536) throw Object.assign(new Error('Claude request is too large'), { code: -32602 });
        store ||= new ClaudeChannelStore(options);
        const p = message.params || {};
        let result;
        switch (message.method) {
          case 'claude/sessions': result = store.list(); break;
          case 'claude/snapshot': result = store.snapshot(p.sessionId, p.before); break;
          case 'claude/send': result = store.submit({ ...p, action: 'message' }); break;
          case 'claude/permission': result = store.submit({ ...p, action: 'permission' }); break;
          case 'claude/receipt': result = { receipt: store.command(p.commandId, p.sessionId) }; break;
          default: throw Object.assign(new Error('Unsupported Claude method'), { code: -32601 });
        }
        send(JSON.stringify({ id: message.id, result }));
      } catch (e) {
        const isInputError = [-32601, -32602].includes(e.code);
        send(JSON.stringify({ id: message.id, error: { code: isInputError ? e.code : -32000, message: isInputError ? e.message : 'Claude local state unavailable' } }));
      }
      return true;
    },
    close() { store?.close(); },
  };
}
module.exports = { createClaudeChannelRouter };
