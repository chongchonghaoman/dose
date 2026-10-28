const fs = require('node:fs/promises');
const path = require('node:path');
const { packager } = require('@electron/packager');
const root = path.resolve(__dirname, '..');

(async () => {
  const pkg = require('../package.json');
  const resources = ['spectral', 'reference', 'reference-editor'].map(name => path.join(root, 'native', name));
  for (const item of resources) {
    await fs.access(item).catch(() => { throw new Error(`Missing ${item}. Run npm run prepare:runtime and npm run build:editor first.`); });
  }
  const paths = await packager({
    dir: root, name: 'dose', platform: 'win32', arch: 'x64',
    out: path.join(root, 'build-output'), overwrite: true, prune: true,
    icon: path.join(root, 'assets/icon.ico'), appVersion: pkg.version, buildVersion: pkg.version,
    extraResource: resources, asar: { unpackDir: 'node_modules/@img' },
    ignore: [/^\/(native|vendor|tests|docs|scripts|licenses|build-output|\.cache|\.sources|\.github|\.git)(?:\/|$)/, /^\/build[^/]*\.(mjs|cjs|ps1)$/, /^\/package-lock\.json$/],
    appCopyright: 'dose contributors; LightTable and SpektraLab contributors. GPL-3.0-or-later.',
    win32metadata: { CompanyName: 'dose', FileDescription: 'dose · Photo & Film Studio', ProductName: 'dose' }
  });
  console.log(paths.join('\n'));
})().catch(error => { console.error(error); process.exitCode = 1; });

