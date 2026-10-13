const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
function showPairing({ pairingPayload }, { background = false } = {}) {
  const QRCode = require('../codex-remote-bridge/node_modules/qrcode-terminal/vendor/QRCode');
  const levels = require('../codex-remote-bridge/node_modules/qrcode-terminal/vendor/QRCode/QRErrorCorrectLevel');
  const qr = new QRCode(-1, levels.M);
  qr.addData(JSON.stringify(pairingPayload)); qr.make();
  const size = qr.getModuleCount();
  let squares = '';
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    if (qr.isDark(y, x)) squares += `<rect x="${x + 4}" y="${y + 4}" width="1" height="1"/>`;
  }
  const directory = path.resolve(__dirname, '../.build/private-pairing');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, 'pair-iphone.html');
  const expiry = Number(pairingPayload.expiresAt);
  fs.writeFileSync(file, `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>CodexLink · iPhone 配对</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:18px -apple-system,sans-serif;text-align:center;background:#f5f5f7;padding:20px;color:#18181b}svg{width:min(72vh,560px);max-width:90vw;background:white;border-radius:12px}p{line-height:1.6}#timer{font-weight:600}</style>
<h1>用 iPhone 的 CodexLink 扫码</h1><p>先连接 Tailscale，再打开 App 内的扫码配对。</p>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size + 8} ${size + 8}" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="white"/><g fill="black">${squares}</g></svg>
<p id="timer"></p><p>${background ? '后台服务已运行，可以关闭终端窗口。' : '保持 Mac 远程服务终端窗口打开。'}</p><script>const expiry=${expiry};function tick(){const s=Math.max(0,Math.ceil((expiry-Date.now())/1000));document.getElementById('timer').textContent=s?'二维码剩余 '+Math.floor(s/60)+' 分 '+s%60+' 秒':'二维码已过期，请运行 scripts/pair-iphone.command。';if(!s)document.querySelector('svg').style.opacity='.15'}tick();setInterval(tick,1000)</script></html>`, { mode: 0o600 });
  console.log(`Large pairing QR: ${file}`);
  execFileSync('open', [file]);
}

module.exports = { showPairing };
