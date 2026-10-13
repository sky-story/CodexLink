const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createMacTerminal, terminalCommand } = require('../src/mac-terminal');
const { ControlStore } = require('../src/control-store');
const threadId = '01a13430-3047-7b23-b69f-38f77c43125e';
const requestId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const endpoint = 'unix:///tmp/isolated-codex.sock';
function fixture(t, overrides = {}) {
  const store = new ControlStore(':memory:'); t.after(() => store.close());
  const calls = [], launches = [];
  const options = { store, endpoint, preflight: () => '/tmp/codex',
    rpc: async (method, params) => { calls.push({ method, params }); return method === 'thread/loaded/list' ? { data: [threadId] } : { thread: { id: threadId, cwd: '/tmp' } }; },
    launch: async command => { launches.push(command); return 'iterm-session'; }, ...overrides };
  return { store, calls, launches, options, opener: createMacTerminal(options) };
}
test('opens exact live thread/socket without turn or permission overrides; duplicate delivery returns same result', async t => {
  const f = fixture(t);
  const results = await Promise.all([f.opener.open({ threadId, requestId }), f.opener.open({ threadId, requestId })]);
  assert.deepEqual(results[0], results[1]); assert.equal(results[0].status, 'opened');
  assert.equal(f.launches.length, 1);
  assert.deepEqual(f.calls.map(c => c.method), ['thread/loaded/list', 'thread/read']);
  assert.deepEqual(f.calls[1].params, { threadId, includeTurns: false });
  assert.match(f.launches[0], /--remote/); assert.match(f.launches[0], /resume/);
  assert.equal(f.store.receipts(threadId).length, 0);
  const restarted = createMacTerminal(f.options);
  assert.deepEqual(await restarted.open({ threadId, requestId }), results[0]); assert.equal(f.launches.length, 1);
});
test('uncertain launch is durable and never replayed after reconnect or runtime reconstruction', async t => {
  let attempts = 0;
  const f = fixture(t, { launch: async () => { attempts++; throw new Error('timeout'); } });
  assert.equal((await f.opener.open({ threadId, requestId })).status, 'unknown');
  assert.equal((await createMacTerminal(f.options).open({ threadId, requestId })).status, 'unknown');
  assert.equal(attempts, 1);
});
test('rejects phone-supplied shell text, cwd, terminal and reused id for different thread', async t => {
  const f = fixture(t);
  for (const extra of [{ command: 'touch /tmp/unwanted' }, { cwd: '/tmp' }, { terminal: 'Terminal' }]) {
    await assert.rejects(f.opener.open({ threadId, requestId, ...extra }));
  }
  await f.opener.open({ threadId, requestId });
  await assert.rejects(f.opener.open({ threadId: requestId, requestId }));
  assert.equal(f.launches.length, 1);
});
test('unloaded history and disconnected daemon never open a terminal', async t => {
  const f = fixture(t, { rpc: async () => ({ data: [] }) });
  assert.equal((await f.opener.open({ threadId, requestId })).status, 'failed');
  assert.equal(f.launches.length, 0);
  const g = fixture(t, { rpc: async () => { throw new Error('offline'); } });
  assert.equal((await g.opener.open({ threadId, requestId })).status, 'failed');
  assert.equal(g.launches.length, 0);
});
test('refuses nonlocal endpoint, invalid UUID, mismatched daemon identity, invalid cwd', async t => {
  const f = fixture(t, { endpoint: 'wss://example.test' });
  assert.equal((await f.opener.open({ threadId, requestId })).status, 'failed');
  await assert.rejects(f.opener.open({ threadId: '../bad', requestId }));
  const g = fixture(t, { rpc: async method => method === 'thread/loaded/list' ? { data: [threadId] } : { thread: { id: requestId, cwd: '/tmp' } } });
  assert.equal((await g.opener.open({ threadId, requestId })).status, 'failed');
  assert.equal(g.launches.length, 0);
  assert.throws(() => terminalCommand({ binary: '/bin/echo', endpoint, threadId, cwd: '/tmp\nmalicious' }));
});
test('shell quoting round-trips spaces, quotes and substitutions as literal arguments', () => {
  const tricky = "unix:///tmp/a b'$(printf INJECTED)`printf BAD`.sock";
  const cmd = terminalCommand({ binary: '/usr/bin/printf', endpoint: tricky, threadId, cwd: '/tmp' });
  // printf receives --remote as its format; use a temporary harmless argument recorder instead.
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "terminal-quote-'"));
  try {
    const binary = path.join(dir, 'args');
    fs.writeFileSync(binary, '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o700 });
    const output = execFileSync('/bin/zsh', ['-f', '-c', terminalCommand({ binary, endpoint: tricky, threadId, cwd: dir })], { encoding: 'utf8' });
    assert.deepEqual(output.trim().split('\n'), ['--remote', tricky, 'resume', threadId]);
  } finally { fs.rmSync(dir, { recursive: true }); }
  assert(cmd.includes('/bin/zsh -f -c'));
});
test('missing app/binary and denied Automation report definite failure without retries', async t => {
  const f = fixture(t, { preflight: () => { throw new Error('missing iTerm'); } });
  assert.equal((await f.opener.open({ threadId, requestId })).status, 'failed'); assert.equal(f.launches.length, 0);
  const g = fixture(t, { launch: async () => { throw Object.assign(new Error('Automation denied'), { definiteFailure: true }); } });
  assert.equal((await g.opener.open({ threadId, requestId })).status, 'failed');
});

test('new empty thread opens a waiting window once without creating a model task', async t => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codexlink-empty-window-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const rollout = path.join(dir, 'not-yet-written.jsonl');
  const f = fixture(t, { rpc: async method => method === 'thread/loaded/list' ? { data: [threadId] } : { thread: { id: threadId, cwd: dir, path: rollout } } });
  const result = await f.opener.open({ threadId, requestId });
  assert.equal(result.status, 'opened');
  assert.equal(result.waitingForFirstMessage, true);
  assert.match(f.launches[0], /1800/);
  assert.match(f.launches[0], /resume/);
  assert.deepEqual(await createMacTerminal(f.options).open({ threadId, requestId }), result);
  assert.equal(f.launches.length, 1);
});

test('waiting shell launches only after a nonempty rollout, with exact quoted thread and socket', async t => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const { spawn } = require('node:child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codexlink-wait-'"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const rollout = path.join(dir, "rollout $(touch BAD).jsonl");
  const output = path.join(dir, 'arguments.json');
  const binary = path.join(dir, 'recorder');
  fs.writeFileSync(binary, '#!/usr/bin/env node\nrequire("fs").writeFileSync(' + JSON.stringify(output) + ', JSON.stringify(process.argv.slice(2)));\n', { mode: 0o700 });
  const child = spawn('/bin/zsh', ['-f', '-c', terminalCommand({ binary, endpoint, threadId, cwd: dir, waitForRollout: rollout })], { stdio: 'pipe' });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  const done = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(new Error('exit ' + code))); });
  await new Promise(resolve => child.stdout.once('data', resolve));
  assert.equal(fs.existsSync(output), false);
  fs.writeFileSync(rollout, '');
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(fs.existsSync(output), false);
  fs.writeFileSync(rollout, '{"type":"session_meta"}\n');
  await done;
  assert.deepEqual(JSON.parse(fs.readFileSync(output)), ['--remote', endpoint, 'resume', threadId]);
  assert.equal(fs.existsSync(path.join(dir, 'BAD')), false);
});
