require('./helpers/isolated-state.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const { readThreadWithLiveFallback } = require('../src/shared-runtime');
const unsupported = () => Object.assign(new Error('list_turns is not supported yet'), { code: -32601 });

test('unsupported history uses only the same daemon loaded thread, preserving live Turn and permissions', async () => {
  const calls = [];
  const thread = { id: 'live', turns: [{ id: 'original', status: 'inProgress', items: [] }] };
  const result = await readThreadWithLiveFallback(async (method, params) => {
    calls.push([method, params]);
    if (method === 'thread/read') throw unsupported();
    if (method === 'thread/loaded/list') return params.cursor ? { data: ['live'], nextCursor: null } : { data: ['other'], nextCursor: 'next' };
    if (method === 'thread/resume') return { thread, approvalPolicy: 'on-request' };
    assert.fail(`Unexpected RPC ${method}`);
  }, { threadId: 'live', includeTurns: true });
  assert.deepEqual(result, { thread });
  assert.deepEqual(calls.at(-1), ['thread/resume', { threadId: 'live' }]);
  assert.equal(calls.filter(([m]) => m === 'thread/resume').length, 1);
});
test('unloaded history never resumes or starts another runtime', async () => {
  const error = unsupported(), calls = [];
  await assert.rejects(readThreadWithLiveFallback(async method => {
    calls.push(method);
    if (method === 'thread/read') throw error;
    assert.equal(method, 'thread/loaded/list');
    return { data: [], nextCursor: null };
  }, { threadId: 'old', includeTurns: true }), e => e === error);
  assert.deepEqual(calls, ['thread/read', 'thread/loaded/list']);
});
test('unrelated errors and metadata reads propagate without fallback', async () => {
  for (const [error, params] of [
    [Object.assign(new Error('not authorized'), { code: -32601 }), { threadId: 'live', includeTurns: true }],
    [Object.assign(new Error('list_turns is not supported yet'), { code: -32600 }), { threadId: 'live', includeTurns: true }],
    [unsupported(), { threadId: 'live', includeTurns: false }],
  ]) {
    let calls = 0;
    await assert.rejects(readThreadWithLiveFallback(async method => { calls++; assert.equal(method, 'thread/read'); throw error; }, params), e => e === error);
    assert.equal(calls, 1);
  }
});
test('successful history is unchanged without extra subscription', async () => {
  const expected = { thread: { id: 'live', turns: [] } };
  let calls = 0;
  assert.equal(await readThreadWithLiveFallback(async method => { calls++; assert.equal(method, 'thread/read'); return expected; }, { threadId: 'live', includeTurns: true }), expected);
  assert.equal(calls, 1);
});
