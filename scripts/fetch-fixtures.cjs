// Public test photos only. Never reads or copies a user's photo library.
const fs = require('node:fs/promises');
const path = require('node:path');
const fixtures = [[1018, '01-valley.jpg'], [1015, '02-river.jpg'], [1016, '03-cliff.jpg'], [1039, '04-waterfall.jpg'], [1043, '05-landscape.jpg'], [1040, '06-castle.jpg']];
(async () => {
  const dir = path.resolve(__dirname, '../tests/fixtures');
  await fs.mkdir(dir, { recursive: true });
  for (const [id, name] of fixtures) {
    const response = await fetch(`https://picsum.photos/id/${id}/1800/1200`);
    if (!response.ok || !response.headers.get('content-type')?.startsWith('image/')) throw new Error(`Fixture ${id}: ${response.status}`);
    await fs.writeFile(path.join(dir, name), Buffer.from(await response.arrayBuffer()));
    console.log(name);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

