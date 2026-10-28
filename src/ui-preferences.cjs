const fs = require('node:fs/promises');
const path = require('node:path');

const DEFAULTS = Object.freeze({ favoriteLuts: [], librarySort: 'added' });
const MAX_FAVORITES = 5000;
const HASH = /^[a-f0-9]{64}$/i;

function clean(input) {
  const value = input && typeof input === 'object' ? input : {};
  const favoriteLuts = Array.isArray(value.favoriteLuts)
    ? [...new Set(value.favoriteLuts.filter(v => typeof v === 'string' && HASH.test(v)).map(v => v.toLowerCase()))].slice(0, MAX_FAVORITES)
    : DEFAULTS.favoriteLuts;
  const librarySort = ['added', 'name', 'name-desc'].includes(value.librarySort) ? value.librarySort : DEFAULTS.librarySort;
  return { favoriteLuts, librarySort };
}

function createUiPreferences(userData) {
  const file = path.join(userData, 'ui-preferences.json');
  let current = { ...DEFAULTS };
  let writeQueue = Promise.resolve();

  async function read() {
    try {
      const parsed = JSON.parse(await fs.readFile(file, 'utf8'));
      current = clean(parsed);
    } catch (error) {
      if (error.code !== 'ENOENT') current = { ...DEFAULTS };
    }
    return { favoriteLuts: [...current.favoriteLuts], librarySort: current.librarySort };
  }

  function save(partial) {
    writeQueue = writeQueue.catch(() => {}).then(async () => {
      await read();
      const candidate = partial && typeof partial === 'object' ? { ...current, ...partial } : current;
      current = clean(candidate);
      await fs.mkdir(userData, { recursive: true });
      const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
      await fs.writeFile(temp, JSON.stringify(current, null, 2), 'utf8');
      await fs.rename(temp, file);
      return { favoriteLuts: [...current.favoriteLuts], librarySort: current.librarySort };
    });
    return writeQueue;
  }

  return { load: read, save, path: file };
}

module.exports = { createUiPreferences, clean, DEFAULTS, MAX_FAVORITES };
