// Reproducible offline renderer plus full dependency notices for the shipped app.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const esbuild = require('esbuild');
const root = path.resolve(__dirname, '../..');
(async () => {
  const output = path.join(root, 'CodexMobile/CodexMobile/Resources/Mermaid/mermaid.min.js');
  const result = await esbuild.build({
    stdin: { contents: "import mermaid from 'mermaid'; globalThis.mermaid = mermaid;", resolveDir: __dirname },
    bundle: true, minify: true, format: 'iife', platform: 'browser', target: 'safari18',
    outfile: output, legalComments: 'inline', metafile: true,
  });
  const packages = new Set();
  for (const input of Object.keys(result.metafile.inputs)) {
    let directory = path.dirname(path.resolve(input));
    while (directory.includes('node_modules')) {
      if (fs.existsSync(path.join(directory, 'package.json')) && JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).name) { packages.add(directory); break; }
      directory = path.dirname(directory);
    }
  }
  const manifest = [];
  const texts = [];
  for (const directory of [...packages].sort()) {
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    let files = fs.readdirSync(directory).filter(f => /^(license|licence|copying|notice)/i.test(f) && fs.statSync(path.join(directory, f)).isFile());
    let license = files.map(f => fs.readFileSync(path.join(directory, f), 'utf8')).join('\n\n');
    if (!license) {
      const readme = fs.readFileSync(path.join(directory, 'README.md'), 'utf8');
      const start = readme.search(/^## License/m);
      if (start < 0) throw new Error('Missing license: ' + pkg.name);
      license = readme.slice(start);
    }
    texts.push(`${pkg.name} ${pkg.version}\n${pkg.license || 'See license text'}\n${license}`);
    manifest.push({ name: pkg.name, version: pkg.version, license: pkg.license || 'See notice' });
  }
  fs.writeFileSync(path.join(root, 'ThirdPartyLicenses/mermaid-bundle.txt'), texts.join('\n\n============================================================\n\n'));
  fs.writeFileSync(path.join(__dirname, 'manifest.json'), JSON.stringify({ mermaid: '11.17.2', sha256: crypto.createHash('sha256').update(fs.readFileSync(output)).digest('hex'), packages: manifest }, null, 2) + '\n');
  const noticeRoot = path.join(root, 'ThirdPartyLicenses');
  const notices = fs.readdirSync(noticeRoot).filter(f => f.endsWith('.txt')).sort().map(f => `${f}\n\n${fs.readFileSync(path.join(noticeRoot, f), 'utf8')}`).join('\n\n============================================================\n\n');
  fs.writeFileSync(path.join(root, 'CodexMobile/CodexMobile/Resources/ThirdPartyNotices.txt'), fs.readFileSync(path.join(root, 'LICENSE'), 'utf8') + '\n\n' + notices);
  console.log(`Built Mermaid and preserved notices for ${manifest.length} bundled packages`);
})();
