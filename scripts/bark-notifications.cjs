#!/usr/bin/env node
// Explicit local management tool. Never print the Bark device key or provider response text.
const fs = require('node:fs');
const path = require('node:path');
const { loadBarkConfig, sendBark, normalizeIconURL, DEFAULT_BARK_ICONS } = require('../codex-remote-bridge/src/bark-push');
const { resolveCodexRemoteStateDir } = require('../codex-remote-bridge/src/daemon-state');
(async () => {
  const stateDir = resolveCodexRemoteStateDir();
  const operation = process.argv[2] || '--status';
  if (operation === '--configure-stdin') {
    const raw = fs.readFileSync(0, 'utf8').trim();
    let url; try { url = new URL(raw); } catch { throw new Error('需要 Bark 首页的完整 HTTPS 网址，不要输入 curl 命令。'); }
    const deviceKey = url.pathname.split('/').filter(Boolean)[0];
    if (url.protocol !== 'https:' || url.username || url.password || !/^[A-Za-z0-9_-]{8,200}$/.test(deviceKey || '')) throw new Error('Bark 网址无效。');
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    // Refuse silently overwriting an existing receiver configuration.
    try { fs.writeFileSync(path.join(stateDir, 'bark-config.json'), JSON.stringify({ enabled: true, serverUrl: url.origin, deviceKey }, null, 2), { mode: 0o600, flag: 'wx' }); }
    catch { throw new Error('未创建配置：文件已存在或无法写入，请先检查本地配置。'); }
    console.log('Bark 配置已私密保存；需通过项目管理脚本更新服务。');
  } else if (operation === '--session-labels') {
    const choice = process.argv[3];
    if (!['on', 'off'].includes(choice)) throw new Error('Expected on or off');
    const file = path.join(stateDir, 'bark-config.json');
    if (!loadBarkConfig({ stateDir }).enabled) throw new Error('Configure Bark first');
    const config = JSON.parse(fs.readFileSync(file, 'utf8'));
    config.includeSessionLabel = choice === 'on';
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(config, null, 2), { mode: 0o600 });
    fs.renameSync(temporary, file);
    console.log(JSON.stringify({ includeSessionLabel: config.includeSessionLabel, restartRequired: true }));
  } else if (operation === '--icon') {
    const [provider, choice] = process.argv.slice(3);
    if (!['codex', 'claude'].includes(provider) || !choice || process.argv.length !== 5) throw new Error('Expected provider and icon');
    const icon = choice === 'default' ? DEFAULT_BARK_ICONS[provider] : normalizeIconURL(choice);
    if (choice !== 'off' && !icon) throw new Error('Expected an HTTPS image URL, default, or off');
    const file = path.join(stateDir, 'bark-config.json');
    if (!loadBarkConfig({ stateDir }).enabled) throw new Error('Configure Bark first');
    const before = fs.readFileSync(file, 'utf8');
    const config = JSON.parse(before);
    if (!config.icons || typeof config.icons !== 'object' || Array.isArray(config.icons)) config.icons = {};
    if (choice === 'off') delete config.icons[provider];
    else config.icons[provider] = icon;
    const temporary = `${file}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temporary, JSON.stringify(config, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
      if (fs.readFileSync(file, 'utf8') !== before) throw new Error('Configuration changed');
      fs.renameSync(temporary, file);
    } finally { fs.rmSync(temporary, { force: true }); }
    console.log(JSON.stringify({ provider, iconEnabled: choice !== 'off', restartRequired: true }));
  } else if (operation === '--send-test') {
    const provider = process.argv[3] || 'codex';
    if (!['codex', 'claude'].includes(provider) || process.argv.length > 4) throw new Error('Expected codex or claude');
    const result = await sendBark(loadBarkConfig({ stateDir }), 'test', { provider });
    const evidence = { at: new Date().toISOString(), provider: 'Bark', source: provider, ...result, physicalLockscreenDeliveryVerified: false,
      note: 'Provider acceptance is not proof of lockscreen delivery; user confirmation required. Generic test text only.' };
    fs.mkdirSync(path.join(__dirname, '../test-results'), { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(__dirname, '../test-results/bark-test-notification.json'), JSON.stringify(evidence, null, 2) + '\n');
    console.log(JSON.stringify(evidence));
    if (result.status !== 'accepted') process.exitCode = 2;
  } else if (operation === '--status') {
    const config = loadBarkConfig({ stateDir });
    console.log(JSON.stringify({ enabled: config.enabled, reason: config.reason, includeSessionLabel: config.includeSessionLabel === true,
      icons: { codex: Boolean(config.icons?.codex), claude: Boolean(config.icons?.claude) } }));
  } else throw new Error('Usage: bark-notifications.cjs --status | --configure-stdin | --session-labels on|off | --icon codex|claude default|off|HTTPS_URL | --send-test [codex|claude]');
})().catch(() => { console.error('Bark 操作未完成，请检查配置、参数或网络。未输出任何私密地址。'); process.exitCode = 1; });
