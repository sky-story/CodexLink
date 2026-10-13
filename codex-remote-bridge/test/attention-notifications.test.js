const test = require('node:test');
const assert = require('node:assert/strict');
const { createAttentionNotifications } = require('../src/attention-notifications');
test('approval/input/errors generate distinct generic APNs events, duplicate approvals are suppressed', async () => {
  const sent = []; const tracker = createAttentionNotifications({ pushServiceClient: { hasConfiguredBaseUrl: true, notifyCompletion: async p => sent.push(p) } });
  await tracker.handleOutbound({ method: 'thread/started', params: { thread: { id: 't', cwd: '/projects/MyApp', name: 'Refactor' } } });
  const approval = { id: 1, method: 'item/commandExecution/requestApproval', params: { threadId: 't', turnId: 'turn', command: 'private command' } };
  await tracker.handleOutbound(approval); await tracker.handleOutbound(approval);
  await tracker.handleOutbound({ ...approval, id: 2, method: 'item/tool/requestUserInput' });
  await tracker.handleOutbound({ method: 'error', params: { threadId: 't', willRetry: false } });
  assert.deepEqual(sent.map(s => s.result), ['approval', 'input', 'error']);
  assert.equal(sent[0].title, 'MyApp · Refactor'); assert(!JSON.stringify(sent).includes('private command'));
});
