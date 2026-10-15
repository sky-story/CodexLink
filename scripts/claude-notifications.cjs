#!/usr/bin/env node
// Install only our observer hooks. Preserve all user settings/permission hooks.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomUUID } = require('node:crypto');
const { HOOK_EVENTS } = require('../codex-remote-bridge/src/claude-notifications');
const { resolveCodexRemoteStateDir } = require('../codex-remote-bridge/src/daemon-state');
const { loadBarkConfig } = require('../codex-remote-bridge/src/bark-push');
const MARKER = '--codexlink-notifications-v1';
const quote = value => `'${String(value).replace(/'/g, `'"'"'`)}'`;
const owned = hook => hook?.type === 'command' && typeof hook.command === 'string'
  && hook.command.includes('claude-notification-hook.js') && hook.command.includes(MARKER);

function updateHooks(settings, { command, remove = false } = {}) {
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) throw new Error('Settings must be an object');
  if (!remove && settings.disableAllHooks === true) throw new Error('Claude hooks are disabled in this settings file');
  const next = structuredClone(settings);
  if (next.hooks != null && (typeof next.hooks !== 'object' || Array.isArray(next.hooks))) throw new Error('Invalid hooks configuration');
  next.hooks ||= {};
  for (const [event, groups] of Object.entries(next.hooks)) {
    if (!Array.isArray(groups) || groups.some(group => !group || !Array.isArray(group.hooks))) throw new Error('Invalid hooks configuration');
    if (!groups.some(group => group.hooks.some(owned))) continue;
    next.hooks[event] = groups.flatMap(group => {
      if (!group.hooks.some(owned)) return [group];
      const hooks = group.hooks.filter(hook => !owned(hook));
      return hooks.length ? [{ ...group, hooks }] : [];
    });
    if (!next.hooks[event].length) delete next.hooks[event];
  }
  if (!remove) for (const event of HOOK_EVENTS) {
    const group = { hooks: [{ type: 'command', command, timeout: 5 }] };
    if (event === 'PreToolUse') group.matcher = 'AskUserQuestion';
    (next.hooks[event] ||= []).push(group);
  }
  if (!Object.keys(next.hooks).length) delete next.hooks;
  return next;
}
function manageHooks({ operation, settingsFile = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json'),
  stateDir = resolveCodexRemoteStateDir(), nodePath = process.execPath, installRuntime = require('./service-runtime.cjs').installRuntime } = {}) {
  if (fs.existsSync(settingsFile) && fs.lstatSync(settingsFile).isSymbolicLink() && operation !== 'status') throw new Error('Claude settings is a symbolic link; refusing to replace it');
  const before = fs.existsSync(settingsFile) ? fs.readFileSync(settingsFile, 'utf8') : null;
  let settings;
  try { settings = before === null ? {} : JSON.parse(before); }
  catch { throw new Error('Claude settings are not valid JSON; nothing was changed'); }
  // Validate even for status; never print settings, credentials, or hook commands.
  updateHooks(settings, { remove: true });
  const count = Object.values(settings.hooks || {}).flatMap(groups => groups.flatMap(group => group.hooks)).filter(owned).length;
  if (operation === 'status') {
    const coverage = HOOK_EVENTS.every(event => (settings.hooks?.[event] || []).some(group =>
      (event !== 'PreToolUse' || group.matcher === 'AskUserQuestion') && group.hooks.some(owned)));
    let deliveries = [], deliveryState = 'not_created';
    const databaseFile = path.join(stateDir, 'notification-deliveries.sqlite');
    if (fs.existsSync(databaseFile)) {
      let db;
      try {
        db = new (require('node:sqlite').DatabaseSync)(databaseFile, { readOnly: true });
        db.exec('PRAGMA busy_timeout=500');
        deliveries = db.prepare('SELECT provider,status,count(*) AS count FROM notices GROUP BY provider,status').all();
        deliveryState = 'readable';
      } catch { deliveryState = 'unavailable'; } finally { db?.close(); }
    }
    return { installed: coverage && count === HOOK_EVENTS.length, hookCount: count,
      hooksDisabledHere: settings.disableAllHooks === true, barkConfigured: loadBarkConfig({ stateDir }).enabled, deliveryState, deliveries };
  }
  if (!['install', 'uninstall'].includes(operation)) throw new Error('Usage: node scripts/claude-notifications.cjs install|status|uninstall');
  if (operation === 'install' && settings.disableAllHooks === true) throw new Error('Claude hooks are disabled; no settings were changed');
  let command;
  if (operation === 'install') {
    if (!loadBarkConfig({ stateDir }).enabled) throw new Error('Configure Bark first using scripts/bark-notifications.cjs');
    const runtime = installRuntime();
    const entry = path.join(runtime.root, 'codex-remote-bridge/bin/claude-notification-hook.js');
    if (!fs.existsSync(entry)) throw new Error('Hook runtime is missing');
    command = [nodePath, '--disable-warning=ExperimentalWarning', entry, '--state-dir', stateDir, MARKER].map(quote).join(' ');
  }
  const next = updateHooks(settings, { command, remove: operation === 'uninstall' });
  if (JSON.stringify(next) === JSON.stringify(settings)) return { changed: false, installed: operation === 'install' };
  const backupDir = path.join(stateDir, 'claude-hook-backups');
  fs.mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  let backup;
  if (before !== null) {
    backup = path.join(backupDir, `settings-${Date.now()}-${randomUUID()}.json`);
    fs.writeFileSync(backup, before, { mode: 0o600, flag: 'wx' });
  }
  fs.mkdirSync(path.dirname(settingsFile), { recursive: true, mode: 0o700 });
  const temp = `${settingsFile}.codexlink-${randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temp, JSON.stringify(next, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
    const current = fs.existsSync(settingsFile) ? fs.readFileSync(settingsFile, 'utf8') : null;
    if (current !== before) throw new Error('Claude settings changed during installation; retry');
    fs.renameSync(temp, settingsFile);
  } finally { fs.rmSync(temp, { force: true }); }
  return { changed: true, installed: operation === 'install', backup,
    note: 'Open a new Claude session to load the updated hooks. Existing sessions were not restarted.' };
}
if (require.main === module) {
  try { console.log(JSON.stringify(manageHooks({ operation: process.argv[2] || 'status' }), null, 2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { manageHooks, updateHooks, MARKER, quote };
