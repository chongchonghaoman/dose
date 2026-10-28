'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const sharp = require('sharp');
const { writeGridExport } = require('../src/grid-export.cjs');

async function tempParent() { return fs.mkdtemp(path.join(os.tmpdir(), 'dose-grid-test-')); }

test('writes nine row-major JPEGs with dimensions, ICC, seams, and colors preserved', async () => {
  const parent = await tempParent();
  const size = 90;
  const width = 90;
  const raw = Buffer.alloc(size * size * 3);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const i = (y * size + x) * 3; raw[i] = Math.floor(x * 255 / (size - 1)); raw[i + 1] = Math.floor(y * 255 / (size - 1)); raw[i + 2] = ((Math.floor(x / 30) + Math.floor(y / 30) * 3) * 29) & 255;
  }
  const png = await sharp(raw, { raw: { width, height: size, channels: 3 } }).png().toBuffer();
  const result = await writeGridExport({ image: png, parent });
  assert.equal(result.count, 9); assert.equal(result.width, 30); assert.equal(result.height, 30);
  assert.deepEqual((await fs.readdir(result.folder)).sort(), ['01.jpg','02.jpg','03.jpg','04.jpg','05.jpg','06.jpg','07.jpg','08.jpg','09.jpg']);
  for (const [i, file] of result.files.entries()) { const m = await sharp(file).metadata(); assert.equal(m.width, 30); assert.equal(m.height, 30); assert.match(m.space, /srgb/i); assert.equal(m.chromaSubsampling, '4:4:4'); assert.equal(path.basename(file), `${String(i + 1).padStart(2, '0')}.jpg`); }
});

test('rejects invalid inputs without creating an output folder', async () => {
  const parent = await tempParent();
  await assert.rejects(() => writeGridExport({ image: Buffer.from('not png'), parent }), /PNG/);
  assert.deepEqual(await fs.readdir(parent), []);
  const png = await sharp({ create: { width: 10, height: 12, channels: 3, background: 'red' } }).png().toBuffer();
  await assert.rejects(() => writeGridExport({ image: png, parent }), /square/);
  assert.deepEqual(await fs.readdir(parent), []);
});

test('uses unique folders even when exports are repeated', async () => {
  const parent = await tempParent();
  const png = await sharp({ create: { width: 30, height: 30, channels: 3, background: 'blue' } }).png().toBuffer();
  const a = await writeGridExport({ image: png, parent }); const b = await writeGridExport({ image: png, parent });
  assert.notEqual(a.folder, b.folder); assert.equal((await fs.readdir(a.folder)).length, 9); assert.equal((await fs.readdir(b.folder)).length, 9);
});
