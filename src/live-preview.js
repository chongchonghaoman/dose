export class LivePreview {
  constructor({ loadLut, onFrame, onError } = {}) {
    this.loadLut = loadLut; this.onFrame = onFrame; this.onError = onError;
    this.worker = new Worker(new URL('./live-preview-worker.js', import.meta.url), { type: 'classic' });
    this.originals = new Map(); this.originalPromises = new Map(); this.luts = new Map(); this.lutPromises = new Map(); this.latest = new Map(); this.pending = new Map();
    this.inFlight = 0; this.generation = 0; this.seq = 0; this.lastSeq = new Map();
    this.worker.onmessage = ({ data }) => this._message(data);
    this.worker.onerror = e => this.onError?.(e.error || new Error(e.message));
  }
  async prepare(id, originalURL, hash = '') {
    let entry = this.originals.get(id);
    if (!entry || entry.url !== originalURL) {
      const prior = this.originalPromises.get(id);
      const promise = prior || (async () => {
      const response = await fetch(originalURL); if (!response.ok) throw Error(`原图加载失败: ${response.status}`);
      const bitmap = await createImageBitmap(await response.blob());
      const scale = Math.min(1, 400 / Math.max(bitmap.width, bitmap.height));
      const width = Math.max(1, Math.round(bitmap.width * scale)), height = Math.max(1, Math.round(bitmap.height * scale));
      const canvas = new OffscreenCanvas(width, height), ctx = canvas.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(bitmap, 0, 0, width, height); bitmap.close();
      entry = { url: originalURL, width, height, pixels: ctx.getImageData(0, 0, width, height).data };
      this.originals.set(id, entry); this._trim(this.originals, 12);
      return entry;
      })(); this.originalPromises.set(id, promise); try { entry = await promise; } finally { this.originalPromises.delete(id); }
    }
    if (hash && !this.luts.has(hash)) {
      const prior = this.lutPromises.get(hash); if (prior) await prior;
      else { if (typeof this.loadLut !== 'function') throw Error('缺少 LUT 加载器'); const promise = (async () => { const lut = await this.loadLut(hash); const raw = lut?.dataArray ?? lut?.data; if (!lut || !raw) throw Error('LUT 加载失败'); const packed = { size: lut.size, min: lut.min, max: lut.max, data: raw instanceof Float32Array ? raw : new Float32Array(raw) };
      this.luts.set(hash, packed); this.worker.postMessage({ type: 'lut', hash, lut: packed }, [packed.data.buffer]);
      this._trim(this.luts, 8); })(); this.lutPromises.set(hash, promise); try { await promise; } finally { this.lutPromises.delete(hash); }
      }
    }
    return entry;
  }
  async request(items = []) {
    const tokens = items.map(item => { const token = { ...item, generation: this.generation, seq: ++this.seq }; this.latest.set(item.id, token); return token; });
    await Promise.all(tokens.map(async token => { try { const source = await this.prepare(token.id, token.url, token.lutHash); if (this.latest.get(token.id) === token) { this.pending.set(token.id, { ...token, source }); this._pump(); } } catch (error) { this.onError?.(error); } }));
  }
  clear() { this.generation++; this.latest.clear(); this.pending.clear(); this.lastSeq.clear(); }
  dispose() { this.clear(); for (const e of this.originals.values()) e.pixels = null; this.originals.clear(); this.luts.clear(); this.worker.terminate(); }
  _pump() { while (this.inFlight < 1 && this.pending.size) { const job = this.pending.values().next().value; this.pending.delete(job.id); this.inFlight++; const pixels = job.source.pixels.buffer.slice(0); this.worker.postMessage({ type: 'render', id: job.id, signature: job.signature, generation: job.generation, seq: job.seq, lutHash: job.lutHash, adjustments: job.adjustments, width: job.source.width, height: job.source.height, pixels }, [pixels]); } }
  _message(data) { this.inFlight = Math.max(0, this.inFlight - 1); if (data.type === 'error') { this.onError?.(Error(data.error)); this._pump(); return; } const current = this.latest.get(data.id), last = this.lastSeq.get(data.id) || 0; if (current && data.generation === this.generation && data.seq >= last) { this.lastSeq.set(data.id, data.seq); this.onFrame?.(data.id, { image: data.image, bloom: data.bloom || null, signature: data.signature, seq: data.seq }); } else { data.image?.close(); data.bloom?.close(); } this._pump(); }
  _trim(map, max) { while (map.size > max) map.delete(map.keys().next().value); }
}
