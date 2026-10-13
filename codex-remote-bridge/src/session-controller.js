// App Server owns the only runtime and its durable queue. This controller owns delivery receipts.
class SessionController {
  constructor({ rpc, store, emit = () => {} }) {
    this.rpc = rpc; this.store = store; this.emit = emit; this.chains = new Map(); this.approvals = new Map(); this.approvalCommands = new Map();
  }
  submit(command) {
    if (!command || typeof command.commandId !== 'string' || !/^[\w-]{8,128}$/.test(command.commandId) || typeof command.threadId !== 'string' || !command.threadId) return Promise.reject(new Error('commandId and threadId are required'));
    if (!['steer', 'queue', 'interrupt', 'approval', 'input', 'settings'].includes(command.action)) return Promise.reject(new Error('Unsupported action'));
    if (['steer', 'queue'].includes(command.action) && (!Array.isArray(command.input) || !command.input.length)) return Promise.reject(new Error('Nonempty input required'));
    if (['steer', 'interrupt'].includes(command.action) && !command.expectedTurnId) return Promise.reject(new Error('expectedTurnId is required'));
    if (command.action === 'settings' && (Object.keys(command).some(k => !['commandId', 'threadId', 'action', 'model', 'effort'].includes(k))
      || typeof command.model !== 'string' || !command.model.trim() || typeof command.effort !== 'string' || !command.effort.trim())) {
      return Promise.reject(new Error('Model and reasoning effort are required; permission overrides are not allowed'));
    }
    const previous = this.chains.get(command.threadId) || Promise.resolve();
    const task = previous.catch(() => {}).then(() => this.execute(command));
    this.chains.set(command.threadId, task);
    task.finally(() => { if (this.chains.get(command.threadId) === task) this.chains.delete(command.threadId); }).catch(() => {});
    return task;
  }
  receipt(id, changes) {
    const receipt = this.store.update(id, changes);
    if (receipt) this.emit({ method: 'remote/command/updated', params: receipt });
    return receipt;
  }
  async execute(command) {
    const entry = this.store.begin(command);
    if (!entry.fresh) return entry.receipt;
    this.emit({ method: 'remote/command/updated', params: entry.receipt });
    const { commandId, threadId, expectedTurnId, input, action } = command;
    try {
      let result;
      if (action === 'steer') {
        result = await this.rpc('turn/steer', { threadId, expectedTurnId, input, clientUserMessageId: commandId });
        if (result.turnId !== expectedTurnId) throw new Error('Upstream returned a different turn');
      } else if (action === 'queue') {
        result = await this.rpc('thread/queue/add', { threadId, input, clientUserMessageId: commandId });
      } else if (action === 'settings') {
        let cursor = null, model;
        do {
          const page = await this.rpc('model/list', { cursor, limit: 100, includeHidden: false });
          model = page.data.find(m => m.model === command.model);
          cursor = page.nextCursor;
        } while (!model && cursor);
        if (!model || !model.supportedReasoningEfforts?.some(e => e.reasoningEffort === command.effort)) {
          throw Object.assign(new Error('The Mac model catalog does not support this model/effort combination'), { code: -32602 });
        }
        await this.rpc('thread/settings/update', { threadId, model: command.model, effort: command.effort });
        // The mutation may have succeeded even if the readback fails. Do not replay it.
        try {
          const { thread } = await this.rpc('thread/read', { threadId, includeTurns: false });
          if (thread.id !== threadId || thread.model !== command.model || thread.reasoningEffort !== command.effort) throw new Error('Settings changed before confirmation');
          result = { model: thread.model, effort: thread.reasoningEffort };
        } catch { throw new Error('Settings sent but confirmation is unavailable; refresh the Mac settings before retrying'); }
      } else if (action === 'interrupt') {
        result = await this.rpc('turn/interrupt', { threadId, turnId: expectedTurnId });
      } else {
        const request = this.approvals.get(JSON.stringify(command.requestId));
        if (!request || request.params.threadId !== threadId) throw Object.assign(new Error('Approval/input request is no longer pending'), { code: -32602 });
        if (action === 'approval' && !['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'].includes(request.method)) throw Object.assign(new Error('This approval type must be reviewed on the Mac'), { code: -32602 });
        if (action === 'input' && !request.method.endsWith('requestUserInput')) throw Object.assign(new Error('Request is not a user-input prompt'), { code: -32602 });
        if (action === 'approval' && !['accept', 'decline', 'cancel'].includes(command.decision)) throw Object.assign(new Error('Only one-time accept, decline or cancel is permitted'), { code: -32602 });
        if (action === 'input' && (!command.answers || typeof command.answers !== 'object')) throw Object.assign(new Error('Answers are required'), { code: -32602 });
        this.approvalCommands.set(JSON.stringify(request.id), commandId);
        result = await this.rpc(null, { id: request.id, result: action === 'approval' ? { decision: command.decision } : { answers: command.answers } });
        this.approvals.delete(JSON.stringify(request.id));
      }
      // An item notification can arrive before the RPC response. Never downgrade observed input.
      const current = this.store.get(commandId);
      const observed = current?.status === 'observed';
      return this.receipt(commandId, { status: observed ? 'observed' : action === 'settings' ? 'applied' : action === 'queue' ? 'queued' : ['approval', 'input'].includes(action) ? 'sent' : 'accepted', result, turnId: (observed && current.turnId) || result?.turnId || expectedTurnId || null });
    } catch (error) {
      // The official event is stronger evidence than a missing RPC response.
      // Preserve both its status and Turn ID; a duplicate still returns this receipt.
      const current = this.store.get(commandId);
      if (current?.status === 'observed') return current;
      return this.receipt(commandId, { status: typeof error.code === 'number' ? 'failed' : 'unknown', detail: error.message });
    }
  }
  observe(message) {
    if (message.id != null && message.method && (/requestApproval$/.test(message.method) || /requestUserInput$/.test(message.method))) this.approvals.set(JSON.stringify(message.id), message);
    if (message.method === 'serverRequest/resolved') {
      const key = JSON.stringify(message.params.requestId);
      this.approvals.delete(key);
      const commandId = this.approvalCommands.get(key);
      if (commandId) { this.receipt(commandId, { status: 'observed', detail: 'Server confirmed that the request was resolved' }); this.approvalCommands.delete(key); }
    }
    const item = message.params?.item;
    if (['item/started', 'item/completed'].includes(message.method) && item?.type === 'userMessage' && item.clientId) {
      this.receipt(item.clientId, { status: 'observed', turnId: message.params.turnId, detail: 'Input is present in the active turn. Model compliance is not guaranteed.' });
    }
  }
}
module.exports = { SessionController };
