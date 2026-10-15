// Translate official Claude hooks into notification events. No transcript parsing,
// model calls, permission decisions, command execution, or prompt text in storage.
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { NotificationStore } = require('./notification-store');
const { hash, canonical } = require('./notification-events');
const { loadBarkConfig, notificationPresentation, cleanLabel } = require('./bark-push');

const HOOK_EVENTS = ['SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'PermissionRequest', 'PreToolUse'];

function recordClaudeHook(input, { stateDir, config = loadBarkConfig({ stateDir }), now = () => Date.now() } = {}) {
  if (!config.enabled) return { status: 'disabled' };
  if (!input || typeof input.session_id !== 'string' || !input.session_id || input.session_id.length > 512
    || !HOOK_EVENTS.includes(input.hook_event_name) || input.agent_id) return { status: 'ignored' };
  const event = input.hook_event_name;
  if (event === 'PreToolUse' && input.tool_name !== 'AskUserQuestion') return { status: 'ignored' };
  const store = new NotificationStore(stateDir, { now });
  try {
    store.prune();
    return store.transaction(() => {
      const sessionKey = hash(['claude', input.session_id]);
      const previous = store.db.prepare('SELECT * FROM claude_sessions WHERE id=?').get(sessionKey);
      // Intake hooks are synchronous and only write local state. Dispatch happens
      // in a detached worker, so a later turn cannot relabel an earlier Stop.
      const nativePrompt = typeof input.prompt_id === 'string' && input.prompt_id.length <= 512 ? input.prompt_id : null;
      const runKey = nativePrompt ? hash(['claude-turn', nativePrompt])
        : ['SessionStart', 'UserPromptSubmit'].includes(event) || !previous ? randomUUID() : previous.run;
      const project = typeof input.cwd === 'string' ? path.basename(input.cwd.replace(/\/+$/, '')) : '';
      const label = config.includeSessionLabel ? cleanLabel(input.session_title) || previous?.label || cleanLabel(project) || null : null;
      store.db.prepare('INSERT INTO claude_sessions VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET run=excluded.run,label=excluded.label,updated_at=excluded.updated_at')
        .run(sessionKey, runKey, label, now());
      let kind, detail;
      if (event === 'Stop') {
        const background = (Array.isArray(input.background_tasks) && input.background_tasks.length > 0)
          || (Array.isArray(input.session_crons) && input.session_crons.length > 0);
        // Stop is a response boundary, not proof that the user's entire goal or
        // all background work succeeded. Other Stop hooks may continue the agent.
        kind = background ? 'background' : 'response_ready';
        detail = kind;
      } else if (event === 'StopFailure') {
        kind = 'failed'; detail = 'api-error';
      } else if (event === 'PermissionRequest' || event === 'PreToolUse') {
        if (typeof input.tool_name !== 'string') return { status: 'ignored' };
        kind = input.tool_name === 'AskUserQuestion' ? 'input' : 'approval';
        // PermissionRequest has no tool_use_id. Coalesce identical requests in
        // one turn; retain only a digest, never tool arguments or question text.
        detail = hash([input.tool_name, canonical(input.tool_input || {})]);
      } else return { status: 'tracked' };
      const id = hash(['claude', sessionKey, runKey, kind, detail]);
      const presentation = notificationPresentation(config, kind, { provider: 'claude', session: { sessionKey, name: label } });
      const fresh = store.enqueue({ provider: 'claude', id, kind, presentation });
      return { status: fresh ? 'queued' : 'duplicate', kind };
    });
  } finally { store.close(); }
}
module.exports = { recordClaudeHook, HOOK_EVENTS };
