// Install a versioned runtime outside Documents so launchd does not depend on folder access prompts.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
function installRuntime({ sourceRoot = path.resolve(__dirname, '..'), installRoot = path.join(os.homedir(), 'Library/Application Support/CodexRemote/runtimes') } = {}) {
  const inputs = ['LICENSE', 'ThirdPartyLicenses', 'codex-remote-bridge/src', 'codex-remote-bridge/bin', 'codex-remote-bridge/package.json',
    'codex-remote-bridge/package-lock.json', 'codex-remote-bridge/node_modules',
    'relay/server.js', 'relay/relay.js', 'relay/push-service.js', 'relay/apns-client.js',
    'relay/package.json', 'relay/package-lock.json', 'relay/node_modules'];
  const files = [];
  function walk(relative) {
    const full = path.join(sourceRoot, relative), stat = fs.lstatSync(full);
    const name = path.basename(full);
    if (stat.isSymbolicLink() || name === '.bin' || name === 'private-defaults.json' || name.startsWith('.env')) return;
    if (stat.isDirectory()) for (const child of fs.readdirSync(full).sort()) walk(path.join(relative, child));
    else if (stat.isFile()) files.push(relative);
  }
  inputs.forEach(walk);
  const hash = createHash('sha256');
  for (const relative of files) { hash.update(relative); hash.update('\0'); hash.update(fs.readFileSync(path.join(sourceRoot, relative))); }
  const revision = hash.digest('hex').slice(0, 20);
  const root = path.join(installRoot, revision);
  fs.mkdirSync(installRoot, { recursive: true, mode: 0o700 });
  if (!fs.existsSync(path.join(root, '.complete'))) {
    const staging = fs.mkdtempSync(path.join(installRoot, '.install-'));
    for (const relative of files) {
      const target = path.join(staging, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
      fs.copyFileSync(path.join(sourceRoot, relative), target);
    }
    fs.writeFileSync(path.join(staging, '.complete'), revision, { mode: 0o600 });
    fs.renameSync(staging, root);
  }
  return { revision, root, cliPath: path.join(root, 'codex-remote-bridge/bin/codex-remote.js') };
}
module.exports = { installRuntime };
