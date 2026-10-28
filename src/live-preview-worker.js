/* CPU preview worker. film.cjs is deliberately shared with the export path. */
importScripts('./auto-fit.js','./film-engine.js');
const lutCache = new Map();

function makeBitmap(data, width, height) {
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext('2d');
  ctx.putImageData(new ImageData(data, width, height), 0, 0);
  return canvas.transferToImageBitmap();
}

self.onmessage = async ({ data: job }) => {
  try {
    if (job.type === 'lut') { lutCache.set(job.hash, job.lut); while (lutCache.size > 16) lutCache.delete(lutCache.keys().next().value); return; }
    if (job.type !== 'render') return;
    const src = new Uint8ClampedArray(job.pixels);
    const lut = job.lutHash ? lutCache.get(job.lutHash) : null;
    if (job.lutHash && !lut) throw Error('预览 LUT 缓存缺失');
    applyPixels(src, 4, job.adjustments, lut);
    applyTexture(src, job.width, job.height, 4, job.adjustments);
    const image = makeBitmap(src, job.width, job.height);
    // Keep bloom geometry consistent with the renderer: a compact 240px bright-feature mask.
    const bw = Math.min(240, job.width), bh = Math.max(1, Math.round(job.height * bw / job.width));
    const bloom = new Uint8ClampedArray(bw * bh * 4);
    for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
      const sx = Math.min(job.width - 1, Math.floor(x * job.width / bw));
      const sy = Math.min(job.height - 1, Math.floor(y * job.height / bh));
      const p = (sy * job.width + sx) * 4;
      const lmax = Math.max(src[p], src[p + 1], src[p + 2]) / 255;
      const alpha = lmax > .65 ? Math.min(255, ((lmax - .65) / .35) ** 2 * 80) : 0;
      const q = (y * bw + x) * 4; bloom[q] = src[p]; bloom[q + 1] = src[p + 1]; bloom[q + 2] = src[p + 2]; bloom[q + 3] = alpha;
    }
    const bloomBitmap = makeBitmap(bloom, bw, bh);
    self.postMessage({ type: 'frame', id: job.id, signature: job.signature, generation: job.generation, seq: job.seq, image, bloom: bloomBitmap }, [image, bloomBitmap]);
  } catch (error) { self.postMessage({ type: 'error', id: job.id, signature: job.signature, error: error?.message || String(error) }); }
};
