'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const sharp = require('sharp');

const LONG_EDGES = new Set([2400, 3600, 4800]);

function num(value, name) {
  if (!Number.isFinite(value)) throw new TypeError(`${name} must be finite`);
  return value;
}

function cleanFormat(format) {
  const f = String(format || 'jpeg').toLowerCase();
  if (f !== 'jpeg' && f !== 'jpg' && f !== 'png') throw new RangeError('format must be jpeg or png');
  return f === 'jpg' ? 'jpeg' : f;
}

function findPhoto(photos, id) {
  if (Array.isArray(photos)) return photos.find((p) => p && (p.id === id || p.photoId === id));
  if (photos && typeof photos === 'object') return photos[id];
  return undefined;
}

/** Render editorial pages without touching source image paths. */
async function writeMagazineExport({ state, parent, format = 'jpeg', longEdge = 3600, resolveImage, onProgress } = {}) {
  if (!state || typeof state !== 'object') throw new TypeError('state is required');
  if (!Array.isArray(state.editorialPages) || state.editorialPages.length === 0) throw new TypeError('state.editorialPages must be a non-empty array');
  if (!Array.isArray(state.items)) throw new TypeError('state.items must be an array');
  if (typeof resolveImage !== 'function') throw new TypeError('resolveImage must be a function');
  if (typeof parent !== 'string' || !parent) throw new TypeError('parent must be a directory path');
  const outputFormat = cleanFormat(format);
  if (!LONG_EDGES.has(longEdge)) throw new RangeError('longEdge must be 2400, 3600, or 4800');
  const canonicalParent = await fs.realpath(parent);
  if (!(await fs.stat(canonicalParent)).isDirectory()) throw new Error('parent must be a directory');

  const pages = state.editorialPages.map((page, index) => {
    if (!page || !Number.isFinite(page.width) || !Number.isFinite(page.height) || page.width <= 0 || page.height <= 0) throw new RangeError(`invalid editorial page ${index}`);
    return { page, index };
  }).sort((a, b) => (Number(a.page.number) - Number(b.page.number)) || (a.index - b.index));
  const itemIds = new Set(state.items.map((item) => item && item.id));
  for (const { page } of pages) for (const id of (Array.isArray(page.itemIds) ? page.itemIds : [])) {
    if (!itemIds.has(id)) throw new Error(`editorial page references missing item ${id}`);
  }
  const scaleFor = (page) => longEdge / Math.max(page.width, page.height);
  let temp;
  try {
    temp = await fs.mkdtemp(path.join(canonicalParent, '.dose-magazine-tmp-'));
    const files = [];
    for (let pi = 0; pi < pages.length; pi += 1) {
      const { page } = pages[pi];
      const scale = scaleFor(page);
      const width = Math.max(1, Math.round(page.width * scale));
      const height = Math.max(1, Math.round(page.height * scale));
      const layers = [];
      for (const item of state.items) {
        if (!item || !Array.isArray(page.itemIds) || !page.itemIds.includes(item.id)) continue;
        const photo = findPhoto(state.photos, item.photoId);
        if (!photo) throw new Error(`missing photo ${item.photoId}`);
        const sourceHeight = item.width * (Number(photo.height) / Number(photo.width));
        if (!Number.isFinite(sourceHeight) || sourceHeight <= 0) throw new RangeError(`invalid dimensions for photo ${item.photoId}`);
        const requestedPixels = Math.min(6000, Math.max(1, Math.ceil(Math.max(item.width * scale, sourceHeight * scale))));
        const source = await resolveImage(photo, requestedPixels);
        if (!(typeof source === 'string' || Buffer.isBuffer(source) || source instanceof Uint8Array)) throw new TypeError(`resolveImage returned invalid image for ${item.photoId}`);
        const iw = Math.max(1, Math.round(num(item.width, 'item.width') * scale));
        const ih = Math.max(1, Math.round(sourceHeight * scale));
        const angle = Number.isFinite(item.angle) ? item.angle : 0;
        if(iw*ih>64000000||Math.max(iw,ih)>16000)throw Error('照片超出了可导出的页面范围，请缩小照片或增大纸面。');
        // Separate pipelines guarantee rotation follows resizing. An edited
        // source can include native film edges and have a different aspect.
        const resized=await sharp(source).resize({width:iw,height:ih,fit:'inside'}).toColourspace('srgb').png().toBuffer();
        const rendered=angle%360?await sharp(resized).rotate(angle,{background:{r:0,g:0,b:0,alpha:0}}).png().toBuffer():resized;
        const meta = await sharp(rendered).metadata();
        let left = Math.round((num(item.x, 'item.x') - page.x) * scale - (meta.width || iw) / 2);
        let top = Math.round((num(item.y, 'item.y') - page.y) * scale - (meta.height || ih) / 2);
        let layer = rendered;
        const right = left + (meta.width || iw), bottom = top + (meta.height || ih);
        const clipLeft = Math.max(0, left), clipTop = Math.max(0, top), clipRight = Math.min(width, right), clipBottom = Math.min(height, bottom);
        if (clipRight <= clipLeft || clipBottom <= clipTop) continue;
        if (clipLeft !== left || clipTop !== top || clipRight !== right || clipBottom !== bottom) {
          layer = await sharp(rendered).extract({ left: clipLeft - left, top: clipTop - top, width: clipRight - clipLeft, height: clipBottom - clipTop }).toBuffer();
          left = clipLeft; top = clipTop;
        }
        layers.push({ input: layer, left, top });
      }
      const ext = outputFormat === 'png' ? 'png' : 'jpg';
      const name = `${String(pi + 1).padStart(2, '0')}.${ext}`;
      const out = path.join(temp, name);
      let image = sharp({ create: { width, height, channels: 3, background: { r: 232, g: 230, b: 227 } } }).composite(layers).withMetadata({ icc: 'srgb' });
      image = outputFormat === 'png' ? image.png() : image.jpeg({ quality: 95, chromaSubsampling: '4:4:4' });
      await image.toFile(out);
      files.push(out);
      if (onProgress) await onProgress({ completed: pi + 1, total: pages.length });
    }
    const folder = path.join(canonicalParent, `dose-magazine-${crypto.randomBytes(5).toString('hex')}`);
    await fs.writeFile(path.join(temp, 'manifest.json'), JSON.stringify({ format: outputFormat, longEdge, pages: files.map((file, i) => ({ file: path.basename(file), width: Math.round(pages[i].page.width * scaleFor(pages[i].page)), height: Math.round(pages[i].page.height * scaleFor(pages[i].page)) })) }, null, 2));
    await fs.rename(temp, folder); temp = null;
    const finalFiles = files.map((file) => path.join(folder, path.basename(file)));
    return { folder, count: finalFiles.length, format: outputFormat, longEdge, files: finalFiles };
  } catch (error) {
    if (temp&&path.dirname(temp)===canonicalParent&&path.basename(temp).startsWith('.dose-magazine-tmp-')) await fs.rm(temp, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

module.exports = { writeMagazineExport };
