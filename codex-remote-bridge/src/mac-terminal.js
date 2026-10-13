// Opens only a live thread on the existing local daemon. No shell input comes from the phone.
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);
const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const quote = value => `'${value.replace(/'/g, `'\\''`)}'`;
const script = `on run argv
  tell application id "com.googlecode.iterm2"
    activate
    set openedWindow to (create window with default profile command (item 1 of argv))
    return (id of current session of openedWindow) as text
  end tell
end run`;
function safePath(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || /[\x00-\x1f\x7f]/.test(value)) throw new Error('Mac 路径无效，未打开窗口。');
  return value;
}
function terminalCommand({ binary, endpoint, threadId, cwd, waitForRollout }) {
  if (!UUID.test(threadId) || !endpoint.startsWith('unix:///')) throw new Error('只能打开本机共享 daemon 的有效会话。');
  safePath(endpoint.slice(7)); safePath(binary); safePath(cwd);
  let wait = '';
  if (waitForRollout) {
    safePath(waitForRollout);
    // Empty legacy threads cannot be resumed until their first user message.
    // Open the window now, but never create a replacement thread or model task.
    wait = `print -r -- 'CodexLink：请在手机发送此会话的第一条消息；就绪后此窗口会自动连接。等待最多 30 分钟，Ctrl+C 可取消。'; for codexlinkWait in {1..1800}; do [[ -s ${quote(waitForRollout)} ]] && break; /bin/sleep 1; done; [[ -s ${quote(waitForRollout)} ]] || { print -r -- '等待超时，请在手机会话菜单重新选择在 Mac 打开。'; exit 1; }; `;
  }
  const command = `cd -- ${quote(cwd)} && { ${wait}exec ${quote(binary)} --remote ${quote(endpoint)} resume ${quote(threadId)}; }`;
  // No login/interactive shell startup files, aliases or command substitution.
  return `/bin/zsh -f -c ${quote(command)}`;
}
function findCodex(env) {
  for (const dir of (env.PATH || '').split(path.delimiter)) {
    if (!path.isAbsolute(dir)) continue;
    const candidate = path.join(dir, 'codex');
    try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch {}
  }
  throw new Error('Mac 后台服务找不到 Codex CLI，请检查服务的 PATH。');
}
async function launchITerm(command) {
  try {
    const { stdout } = await run('/usr/bin/osascript', ['-e', script, command], { timeout: 20000, maxBuffer: 65536 });
    return stdout.trim();
  } catch (error) {
    if (String(error.stderr).includes('-1743')) throw Object.assign(new Error('macOS 未允许后台服务控制 iTerm。请在 Mac 系统设置 → 隐私与安全性 → 自动化中允许相应控制权限。'), { definiteFailure: true });
    throw new Error('iTerm 打开结果不确定。请先查看 Mac 窗口和系统自动化授权提示；为避免重复打开，本请求不会自动重发。');
  }
}
function createMacTerminal({ rpc, store, endpoint, env = process.env, platform = process.platform, launch = launchITerm, preflight = () => {
  if (platform !== 'darwin') throw new Error('在 Mac 打开会话仅支持 macOS。');
  if (!fs.existsSync('/Applications/iTerm.app') && !fs.existsSync(path.join(require('node:os').homedir(), 'Applications/iTerm.app'))) throw new Error('Mac 尚未安装 iTerm，请先安装 iTerm。');
  if (!fs.statSync(endpoint.slice(7)).isSocket()) throw new Error('共享 daemon socket 不可用。');
  return findCodex(env);
} }) {
  // Separate from model-control receipts. A crash after dispatch must never replay a window open.
  store.db.exec('CREATE TABLE IF NOT EXISTS terminal_opens(id TEXT PRIMARY KEY, thread TEXT NOT NULL, value TEXT NOT NULL)');
  const pending = new Map();
  function save(id, thread, result) {
    store.db.prepare('INSERT OR REPLACE INTO terminal_opens VALUES(?,?,?)').run(id, thread, JSON.stringify(result));
    return result;
  }
  async function open(params) {
    if (!params || Object.keys(params).some(k => !['threadId', 'requestId'].includes(k)) || !UUID.test(params.threadId) || !UUID.test(params.requestId)) throw new Error('打开会话请求无效。');
    const { requestId, threadId } = params;
    const old = store.db.prepare('SELECT thread,value FROM terminal_opens WHERE id=?').get(requestId);
    if (old) {
      if (old.thread !== threadId) throw new Error('requestId 已用于其他会话。');
      return pending.get(requestId) || JSON.parse(old.value);
    }
    // Reserve before any await, including discovery, so concurrent deliveries cannot open twice.
    save(requestId, threadId, { status: 'unknown', detail: '打开结果尚未确认，请检查 Mac；不会自动重发。' });
    const work = (async () => {
      let dispatched = false;
      try {
        if (!endpoint.startsWith('unix:///')) throw new Error('需要本机共享 daemon 连接。');
        const binary = preflight();
        let cursor = null, loaded = false;
        do {
          const page = await rpc('thread/loaded/list', { limit: 100, cursor });
          loaded = page.data.includes(threadId); cursor = page.nextCursor;
        } while (!loaded && cursor);
        if (!loaded) throw new Error('此会话当前未在 Mac daemon 中加载。请先打开会话后再试。');
        const { thread } = await rpc('thread/read', { threadId, includeTurns: false });
        if (thread.id !== threadId) throw new Error('会话身份不匹配，未打开窗口。');
        const waitForRollout = thread.path && !fs.existsSync(thread.path) ? thread.path : undefined;
        const command = terminalCommand({ binary, endpoint, threadId, cwd: thread.cwd, waitForRollout });
        dispatched = true;
        const sessionId = await launch(command);
        return save(requestId, threadId, { status: 'opened', terminal: 'iTerm', sessionId, threadId, waitingForFirstMessage: Boolean(waitForRollout) });
      } catch (error) {
        return save(requestId, threadId, { status: dispatched && !error.definiteFailure ? 'unknown' : 'failed', detail: error.message });
      }
    })();
    pending.set(requestId, work);
    try { return await work; } finally { pending.delete(requestId); }
  }
  return { open };
}
module.exports = { createMacTerminal, terminalCommand, launchITerm };
