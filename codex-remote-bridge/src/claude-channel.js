const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { ListToolsRequestSchema, CallToolRequestSchema } = require('@modelcontextprotocol/sdk/types.js');
const { z } = require('zod');
const { ClaudeChannelStore } = require('./claude-channel-store');

function createClaudeChannel({ sessionId, generation, store = new ClaudeChannelStore(), transport = new StdioServerTransport(), intervalMs = 250 } = {}) {
  store.requireSession(sessionId, generation);
  const server = new Server({ name: 'codexlink', version: '0.1.0' }, {
    capabilities: { experimental: { 'claude/channel': {}, 'claude/channel/permission': {} }, tools: {} },
    instructions: 'CodexLink connects the owner’s paired iPhone to this same local session. Messages arrive as <channel source="codexlink" message_id="...">. '
      + 'Respond to each phone message using the reply tool, copying its message_id exactly. Replies go only to that paired phone. '
      + 'You may also show progress in the terminal. The channel queues messages when you are busy; do not claim to interrupt work. '
      + 'Permission verdicts are handled by the channel protocol and explicit phone buttons, never by interpreting chat text or by calling reply.',
  });
  let timer, pumping = false, stopped = false, lastHeartbeat = 0;
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [{
    name: 'reply', description: 'Reply to a message from the paired CodexLink iPhone in this session.',
    inputSchema: { type: 'object', properties: { message_id: { type: 'string' }, text: { type: 'string', maxLength: 8000 } }, required: ['message_id', 'text'], additionalProperties: false },
  }] }));
  server.setRequestHandler(CallToolRequestSchema, async request => {
    if (request.params.name !== 'reply') throw new Error('Unknown channel tool');
    const args = request.params.arguments || {};
    store.reply(sessionId, generation, args.message_id, args.text);
    return { content: [{ type: 'text', text: 'Reply saved for the paired iPhone.' }] };
  });
  server.setNotificationHandler(z.object({
    method: z.literal('notifications/claude/channel/permission_request'),
    params: z.object({ request_id: z.string(), tool_name: z.string(), description: z.string(), input_preview: z.string() }),
  }), async ({ params }) => { store.permission(sessionId, generation, params); });
  server.onerror = () => {}; // Never print MCP payloads, tool arguments, or credentials.
  async function pump() {
    if (pumping || stopped) return;
    pumping = true;
    try {
      if (Date.now() - lastHeartbeat >= 2000) { store.heartbeat(sessionId, generation); lastHeartbeat = Date.now(); }
      for (let i = 0; i < 10 && !stopped; i++) {
        const command = store.claim(sessionId, generation);
        if (!command) break;
        if (command.skipped) continue;
        try {
          if (command.action === 'message') {
            await server.notification({ method: 'notifications/claude/channel', params: { content: command.payload.text, meta: { message_id: command.id } } });
          } else {
            await server.notification({ method: 'notifications/claude/channel/permission', params: { request_id: command.payload.relayId, behavior: command.payload.behavior } });
          }
          store.finish(command.id, 'sent', command.action === 'message' ? 'Written to Claude channel; awaiting reply' : 'Verdict sent; Claude applies the first answer, including Mac decisions');
        } catch { /* Claim remains unknown. A reconnect never resends it. */ }
      }
    } finally { pumping = false; }
  }
  server.oninitialized = () => {
    store.heartbeat(sessionId, generation);
    timer = setInterval(() => { pump().catch(() => {}); }, intervalMs);
  };
  server.onclose = () => { stopped = true; clearInterval(timer); try { store.closeSession(sessionId, generation); } catch {} };
  return {
    server, pump,
    async start() { await server.connect(transport); },
    async close() { stopped = true; clearInterval(timer); await server.close(); store.close(); },
  };
}
module.exports = { createClaudeChannel };
