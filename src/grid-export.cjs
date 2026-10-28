'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const MAX_ENCODED_BYTES = 128 * 1024 * 1024;
const MIN_SIZE = 3;
const MAX_SIZE = 6000;

function isWithin(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

async function removeCreatedFolder(folder, parent) {
  try {
    const canonicalFolder = await fs.realpath(folder);
    if (!isWithin(parent, canonicalFolder) || path.dirname(canonicalFolder) !== parent || canonicalFolder !== path.resolve(folder) || !path.basename(canonicalFolder).startsWith('dose-九宫格-')) return false;
    await fs.rm(canonicalFolder, { recursive: true, force: true });
    return true;
  } catch {
    return false;
  }
}

/**
 * Export a rendered square 3x3 PNG composite to nine row-major JPEG tiles.
 * @param {{image: Buffer|Uint8Array, parent: string}} options
 */
async function writeGridExport({ image, parent } = {}) {
  if (!(Buffer.isBuffer(image) || image instanceof Uint8Array)) {
    throw new TypeError('image must be a Buffer or Uint8Array');
  }
  if (image.byteLength > MAX_ENCODED_BYTES) {
    throw new RangeError('encoded image exceeds 128 MiB limit');
  }
  if (typeof parent !== 'string' || parent.length === 0) {
    throw new TypeError('parent must be a non-empty directory path');
  }
  const input = Buffer.isBuffer(image) ? image : Buffer.from(image);
  if (input.length < PNG_MAGIC.length || !input.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) {
    throw new TypeError('image must be a PNG');
  }

  const canonicalParent = await fs.realpath(parent);
  const parentStat = await fs.stat(canonicalParent);
  if (!parentStat.isDirectory()) throw new Error('parent must be a directory');

  let metadata;
  try {
    metadata = await sharp(input, { limitInputPixels: MAX_SIZE * MAX_SIZE }).metadata();
  } catch (error) {
    throw new TypeError(`invalid PNG: ${error.message}`);
  }
  const { width, height } = metadata;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width !== height || width < MIN_SIZE || width > MAX_SIZE || width % 3 !== 0) {
    throw new RangeError('PNG must be square, 3..6000 pixels, and divisible by 3');
  }

  let folder;
  try {
    folder = await fs.mkdtemp(path.join(canonicalParent, 'dose-九宫格-'));
    const canonicalFolder = await fs.realpath(folder);
    if (!isWithin(canonicalParent, canonicalFolder) || canonicalFolder === canonicalParent) {
      throw new Error('created export folder escaped parent');
    }
    const tile = width / 3;
    const files = [];
    for (let row = 0; row < 3; row += 1) {
      for (let col = 0; col < 3; col += 1) {
        const name = `${String(row * 3 + col + 1).padStart(2, '0')}.jpg`;
        const file = path.join(folder, name);
        await sharp(input)
          .extract({ left: col * tile, top: row * tile, width: tile, height: tile })
          .withMetadata({ icc: 'srgb' })
          .jpeg({ quality: 95, chromaSubsampling: '4:4:4' })
          .toFile(file);
        files.push(file);
      }
    }
    return { count: 9, folder, files, width: tile, height: tile };
  } catch (error) {
    if (folder) {
      const cleaned = await removeCreatedFolder(folder, canonicalParent);
      if (!cleaned) error.message += ` (failed export folder preserved at ${folder})`;
    }
    throw error;
  }
}

module.exports = { writeGridExport, MAX_ENCODED_BYTES };
