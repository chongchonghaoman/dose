const { _electron } = require('playwright');
const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const FilmFrame = require('../src/film-frame.js');

const root = path.resolve(__dirname, '..');
const version = require('../package.json').version;
const out = process.env.DOSE_VERIFY_OUTPUT || path.resolve(root, `../../outputs/v${version}/verification`);
const profile = path.join(__dirname, 'results/viewport-profile-' + Date.now());
const env = { ...process.env, LIGHTTABLE_USER_DATA: profile };
delete env.ELECTRON_RUN_AS_NODE;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

function photoHash(file) { return crypto.createHash('sha256').update(fsSync.readFileSync(file)).digest('hex'); }
function signature(state) {
  return (state.items || []).map(item => [item.id, +(item.x || 0).toFixed(3), +(item.y || 0).toFixed(3), +(item.width || 0).toFixed(3)]).sort((a, b) => String(a[0]).localeCompare(String(b[0])));
}
function rectangles(state) {
  return (state.items || []).map(item => {
    const photo = (state.photos || []).find(candidate => candidate.id === item.photoId) || {};
    const h = item.width * (photo.height || 1) / (photo.width || 1);
    const frame = item.presentation === 'print' ? FilmFrame.metrics(item.width, h, 'bare', false) : FilmFrame.metrics(item.width, h, item.mount, item.sprockets !== false);
    return { x: item.x - frame.ow / 2, y: item.y - frame.oh / 2, w: frame.ow, h: frame.oh };
  });
}
function overlap(a, b) { return a.x < b.x + b.w - 1e-6 && a.x + a.w > b.x + 1e-6 && a.y < b.y + b.h - 1e-6 && a.y + a.h > b.y + 1e-6; }

(async () => {
  await fs.mkdir(out, { recursive: true });
  let app, page;
  const errors = [], checks = [];
  async function start() {
    const launch = process.env.LIGHTTABLE_EXECUTABLE ? { executablePath: process.env.LIGHTTABLE_EXECUTABLE, args: [], env } : { args: [root], env };
    app = await _electron.launch(launch);
    page = await app.firstWindow();
    await app.evaluate(({ BrowserWindow }) => { const win = BrowserWindow.getAllWindows()[0]; win.webContents.setBackgroundThrottling(false); win.hide(); });
    page.on('pageerror', error => errors.push(error.message));
    await page.waitForSelector('#import');
  }
  async function saved() { await wait(700); return (await page.evaluate(() => window.lighttable.load())).state; }
  async function setSize(width, height) { await app.evaluate(({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setSize(size.width, size.height), { width, height }); await wait(220); return saved(); }
  async function assertVisible(state) {
    const stage = await page.locator('#stage').boundingBox();
    const camera = state.camera || {}, zoom = camera.zoom || 1;
    const rects = rectangles(state);
    for (let index = 0; index < rects.length; index++) {
      const rect = rects[index];
      const item = state.items[index];
      const cx = stage.width / 2 + (camera.x || 0) + item.x * zoom;
      const cy = stage.height / 2 + (camera.y || 0) + item.y * zoom;
      assert(cx - rect.w * zoom / 2 >= -1e-3 && cx + rect.w * zoom / 2 <= stage.width + 1e-3, 'frame outside visible stage width');
      assert(cy - rect.h * zoom / 2 >= -1e-3 && cy + rect.h * zoom / 2 <= stage.height + 1e-3, 'frame outside visible stage height');
    }
  }
  try {
    await start();
    const fixtures = (await fs.readdir(path.join(__dirname, 'fixtures'))).filter(name => /^0.*\.jpg$/i.test(name)).slice(0, 6).map(name => path.join(__dirname, 'fixtures', name));
    assert.equal(fixtures.length, 6, 'six JPEG fixtures required');
    const hashes = fixtures.map(photoHash);
    await app.evaluate(({ dialog }, files) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: files }); }, fixtures);
    await page.click('#import');
    await page.waitForFunction(() => document.querySelectorAll('.film-thumb').length === 6, null, { timeout: 120000 });
    await page.locator('#toast button').click().catch(() => {});
    const initial = await saved();
    const adjustments = (initial.photos || []).map(photo => photo.adjustments);

    await page.selectOption('#layout-style', 'editorial');
    await page.click('#auto-layout');
    const magazineBefore = await saved();
    await page.locator('.film-thumb').first().click();
    await page.locator('#table').focus();
    await page.keyboard.press('Delete');
    const afterRemoval = await saved();
    assert.equal(afterRemoval.photos.length, 6);
    assert.equal(afterRemoval.items.length, 5, 'one selected staged item should be removed');
    await page.selectOption('#layout-style', 'viewport');
    const wide = await setSize(1400, 800);
    assert.equal(wide.layoutStyle, 'viewport');
    assert.equal((wide.editorialPages || []).length, 1);
    assert.equal(wide.editorialPages[0].kind, 'viewport');
    assert.equal((wide.items || []).length, 6);
    assert(wide.items.every(item => item.layoutSizing === 'viewport'));
    assert.deepEqual((wide.photos || []).map(photo => photo.adjustments), adjustments);
    await assertVisible(wide);
    await page.screenshot({ path: path.join(out, 'viewport-wide.png') });
    checks.push('Viewport mode explicitly brings all six library photos into the layout and preserves adjustments');
    const firstVariation = signature(wide);
    await page.click('#auto-layout');
    const variation = await saved();
    assert.equal(variation.items.length, 6);
    assert.notDeepEqual(signature(variation), firstVariation, 'explicit next viewport layout should vary composition');
    await page.keyboard.press('Control+z');
    await saved();
    const wideSig = signature(wide);
    const wideRects = rectangles(wide);
    for (let i = 0; i < wideRects.length; i++) for (let j = i + 1; j < wideRects.length; j++) assert(!overlap(wideRects[i], wideRects[j]), 'viewport photos overlap');

    await page.keyboard.press('Control+z');
    const undone = await saved();
    assert.equal(undone.layoutStyle, 'editorial');
    assert((undone.editorialPages || []).length > 0, 'undo should restore magazine pages');
    await page.keyboard.press('Control+Shift+z');
    const redone = await saved();
    assert.deepEqual(signature(redone), wideSig);
    assert.notDeepEqual(signature(undone), wideSig);
    checks.push('Viewport mode undo/redo restores geometry');
    const tall = await setSize(980, 1200);
    assert.notDeepEqual(signature(tall), wideSig, 'wide/tall viewport geometry should differ');
    checks.push('Window resize reflows viewport geometry for wide and tall stages');
    await app.close(); app = null; await start();
    await page.waitForFunction(() => document.querySelectorAll('.film-thumb').length === 6, null, { timeout: 120000 });
    const restored = await saved();
    assert.equal(restored.layoutStyle, 'viewport');
    await assertVisible(restored);
    checks.push('Restart preserves viewport mode and reflows current window');
    await page.selectOption('#layout-style', 'editorial');
    await page.click('#auto-layout');
    const magazine = await saved();
    assert.equal(magazine.layoutStyle, 'editorial');
    await page.selectOption('#layout-style', 'viewport');
    assert.equal((await saved()).layoutStyle, 'viewport');
    checks.push('Explicit viewport mode switches from magazine mode and restores all library photos');
    for (const [i, file] of fixtures.entries()) assert.equal(photoHash(file), hashes[i], 'fixture source changed');
    await fs.writeFile(path.join(out, 'viewport-desktop-report.json'), JSON.stringify({ version, packaged: !!process.env.LIGHTTABLE_EXECUTABLE, checks, errors }, null, 2));
    await setSize(800, 1400); await page.screenshot({ path: path.join(out, 'viewport-tall.png') });
    const beforePanel = await saved();
    const stageBeforePanel = await page.locator('#stage').boundingBox();
    await page.locator('.film-thumb').first().click();
    await page.click('#film-color');
    await page.waitForSelector('#film-panel:not([hidden])');
    const stageWithPanel = await page.locator('#stage').boundingBox();
    assert(stageWithPanel.width < stageBeforePanel.width, 'film panel should shrink stage width');
    const panelState = await saved();
    assert.match(await page.locator('#film-scope').textContent(), /已选\s*1\s*张/, 'film panel should retain one selected photo');
    await assertVisible(panelState);
    const panelRects = rectangles(panelState);
    for (let i = 0; i < panelRects.length; i++) for (let j = i + 1; j < panelRects.length; j++) assert(!overlap(panelRects[i], panelRects[j]), 'panel viewport photos overlap');
    await page.screenshot({ path: path.join(out, 'viewport-panel.png') });
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ checks }, null, 2));
  } catch (error) {
    if (page) await page.screenshot({ path: path.join(out, 'viewport-desktop-failure.png') }).catch(() => {});
    console.error('Page errors', errors);
    throw error;
  } finally { await app?.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
