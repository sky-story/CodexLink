const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const { defaultEndpoint } = require('../codex-remote-bridge/src/shared-runtime');
try {
  const version = execFileSync('codex', ['--version'], { encoding: 'utf8' }).trim();
  const daemon = JSON.parse(execFileSync('codex', ['app-server', 'daemon', 'version'], { encoding: 'utf8' }));
  const path = defaultEndpoint().slice(7);
  console.log(JSON.stringify({ version, testedVersion: '0.162.1', exactVersionMatch: version === 'codex-cli 0.162.1', node: process.version, daemonRunning: daemon.status === 'running', daemonVersion: daemon.appServerVersion, controlSocketPresent: fs.existsSync(path), liveSharingRequires: 'TUI and Bridge connected to the same daemon; --no-daemon sessions cannot be adopted', remoteListener: 'Relay defaults to 127.0.0.1; no public deployment' }, null, 2));
  if (version !== 'codex-cli 0.162.1' || daemon.appServerVersion !== '0.162.1') process.exitCode = 1;
} catch (error) { console.error(error.message); process.exitCode = 1; }
