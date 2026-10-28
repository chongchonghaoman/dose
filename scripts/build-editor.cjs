const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const cwd = path.join(root, 'vendor/spektralab/desktop');
for (const args of [['run', 'typecheck'], ['run', 'build:web', '--', '--base', './']]) {
  const result = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, { cwd, stdio: 'inherit', shell: process.platform === 'win32' });
  if (result.error || result.status !== 0) { console.error(result.error || 'Editor build failed'); process.exit(1); }
}
fs.cpSync(path.join(cwd, 'dist'), path.join(root, 'native/reference-editor'), { recursive: true });
console.log('Editor staged in native/reference-editor');

