const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createUiPreferences } = require('../src/ui-preferences.cjs');

const hash = 'A'.repeat(64);

test('preferences persist across reopening', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'dose-preferences-'));
  const first = createUiPreferences(dir);
  assert.deepEqual(await first.load(), { favoriteLuts: [], librarySort: 'added' });
  assert.deepEqual(await first.save({ favoriteLuts: [hash], librarySort: 'name-desc' }), { favoriteLuts: [hash.toLowerCase()], librarySort: 'name-desc' });
  const reopened = createUiPreferences(dir);
  assert.deepEqual(await reopened.load(), { favoriteLuts: [hash.toLowerCase()], librarySort: 'name-desc' });
  assert.equal((await fs.stat(path.join(dir, 'ui-preferences.json'))).isFile(), true);
});

test('concurrent saves merge fields without loss', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'dose-preferences-'));
  const preferences = createUiPreferences(dir);
  const [a, b] = await Promise.all([
    preferences.save({ favoriteLuts: ['b'.repeat(64)] }),
    preferences.save({ librarySort: 'name' })
  ]);
  assert.deepEqual((await preferences.load()), { favoriteLuts: ['b'.repeat(64)], librarySort: 'name' });
  assert.deepEqual(b, { favoriteLuts: ['b'.repeat(64)], librarySort: 'name' });
  assert.equal(a.librarySort, 'added');
});

test('invalid values are cleaned and favorites are deduplicated', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'dose-preferences-'));
  const preferences = createUiPreferences(dir);
  const result = await preferences.save({ favoriteLuts: [hash, hash.toLowerCase(), 'bad', 3, 'f'.repeat(65)], librarySort: 'other' });
  assert.deepEqual(result, { favoriteLuts: [hash.toLowerCase()], librarySort: 'added' });
});
