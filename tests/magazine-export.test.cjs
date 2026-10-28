'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const sharp = require('sharp');
const { writeMagazineExport } = require('../src/magazine-export.cjs');

async function tmp() { return fs.mkdtemp(path.join(os.tmpdir(), 'dose-magazine-test-')); }
async function solid(r, g, b, w = 20, h = 10) { return sharp({ create: { width: w, height: h, channels: 3, background: { r, g, b } } }).png().toBuffer(); }
function state(pages, items, photos) { return { photos, items, editorialPages: pages }; }
async function pixel(file,x,y){return [...await sharp(file).extract({left:x,top:y,width:1,height:1}).removeAlpha().raw().toBuffer()];}
const paper=[232,230,227];
function pageFor(ids){return {number:1,x:100,y:200,width:100,height:100,itemIds:ids};}

test('exports pages in stable number order with dimensions and sRGB metadata', async () => {
  const parent = await tmp();
  const red = await solid(255, 0, 0);
  const result = await writeMagazineExport({ parent, longEdge: 2400, format: 'png', state: state([
    { number: 2, x: 0, y: 0, width: 100, height: 200, itemIds: ['b'] },
    { number: 1, x: 0, y: 0, width: 200, height: 100, itemIds: ['a'] },
    { number: 1, x: 0, y: 0, width: 200, height: 100, itemIds: ['c'] },
  ], [
    { id: 'a', photoId: 'p', x: 30, y: 30, width: 30, height: 30 },
    { id: 'b', photoId: 'p', x: 30, y: 30, width: 30, height: 30 },
    { id: 'c', photoId: 'p', x: 30, y: 30, width: 30, height: 30 },
  ], [{ id: 'p', width: 20, height: 10 }] ), resolveImage: async () => red });
  assert.equal(result.count, 3);
  assert.deepEqual(result.files.map((f) => path.basename(f)), ['01.png', '02.png', '03.png']);
  assert.equal((await sharp(result.files[0]).metadata()).width, 2400);
  assert.equal((await sharp(result.files[0]).metadata()).height, 1200);
  assert.match(String((await sharp(result.files[0]).metadata()).space), /srgb/i);
  assert.equal((await fs.stat(path.join(result.folder, 'manifest.json'))).isFile(), true);
});

test('preserves rotation and clips negative offsets at paper boundary', async () => {
  const parent = await tmp();
  const blue = await solid(0, 0, 255, 10, 20);
  const result = await writeMagazineExport({ parent, longEdge: 2400, format: 'png', state: state([
    { number: 1, x: 0, y: 0, width: 100, height: 100, itemIds: ['a', 'b'] },
  ], [
    { id: 'a', photoId: 'p', x: 0, y: 0, width: 60, height: 60, angle: 90 },
    { id: 'b', photoId: 'p', x: -20, y: -20, width: 80, height: 80, angle: 0 },
  ], [{ id: 'p', width: 10, height: 20 }] ), resolveImage: async () => blue });
  const meta = await sharp(result.files[0]).metadata();
  assert.equal(meta.width, 2400); assert.equal(meta.height, 2400);
  const { data, info } = await sharp(result.files[0]).raw().toBuffer({ resolveWithObject: true });
  assert.equal(info.width, 2400); assert.equal(info.height, 2400);
  assert(data.some((v) => v > 180));
});

test('missing source rejects and leaves no magazine folder', async () => {
  const parent = await tmp();
  await assert.rejects(() => writeMagazineExport({ parent, longEdge: 2400, state: state([
    { number: 1, x: 0, y: 0, width: 100, height: 100, itemIds: ['missing'] },
  ], [{ id: 'missing', photoId: 'unknown', x: 0, y: 0, width: 20, height: 20 }], []), resolveImage: async () => { throw new Error('should not resolve'); } }));
  assert.deepEqual((await fs.readdir(parent)).filter((n) => n.startsWith('dose-magazine')), []);
});

test('clockwise rotation matches canvas and JPEG files carry an ICC profile',async()=>{
 const parent=await tmp(),image=await sharp({create:{width:80,height:40,channels:3,background:'red'}}).composite([{input:await solid(0,0,255,40,40),left:40,top:0}]).png().toBuffer();
 const s=state([pageFor(['a'])],[{id:'a',photoId:'p',x:150,y:250,width:60,angle:90}],[{id:'p',width:80,height:40}]);
 const sizes=[],png=await writeMagazineExport({state:s,parent,format:'png',longEdge:2400,resolveImage:async(p,size)=>{sizes.push(size);return image;}});
 assert.equal(typeof sizes[0],'number');assert.equal(sizes[0],1440);
 assert.deepEqual(await pixel(png.files[0],1200,750),[255,0,0]);
 assert.deepEqual(await pixel(png.files[0],1200,1650),[0,0,255]);
 assert.deepEqual(await pixel(png.files[0],650,1200),paper);
 const jpg=await writeMagazineExport({state:s,parent,format:'jpeg',longEdge:2400,resolveImage:async()=>image});
 const meta=await sharp(jpg.files[0]).metadata();assert.equal(meta.format,'jpeg');assert(meta.icc?.length>0);assert.equal(meta.width,2400);
});

test('clips oversized layers, preserves stacking and contains changed source proportions',async()=>{
 const parent=await tmp(),red=await solid(255,0,0,80,40),blue=await solid(0,0,255,20,20);
 const s=state([pageFor(['a','b'])],[{id:'a',photoId:'p',x:100,y:250,width:160,angle:0},{id:'b',photoId:'q',x:150,y:250,width:20,angle:0}],[{id:'p',width:80,height:40},{id:'q',width:20,height:20}]);
 const result=await writeMagazineExport({state:s,parent,format:'png',longEdge:2400,resolveImage:async p=>p.id==='p'?red:blue});
 assert.deepEqual(await pixel(result.files[0],100,1200),[255,0,0]);assert.deepEqual(await pixel(result.files[0],1200,1200),[0,0,255]);
 assert.deepEqual(await pixel(result.files[0],2200,1200),paper);
 // The processed source is square, although its original metadata was 2:1.
 const changed=state([pageFor(['a'])],[{id:'a',photoId:'q',x:150,y:250,width:60,angle:0}],[{id:'q',width:80,height:40}]);
 const contained=await writeMagazineExport({state:changed,parent,format:'png',longEdge:2400,resolveImage:async()=>blue});
 assert.deepEqual(await pixel(contained.files[0],600,1200),paper);assert.deepEqual(await pixel(contained.files[0],1200,1200),[0,0,255]);
});

test('stale members and a later source failure never publish partial pages',async()=>{
 const parent=await tmp(),red=await solid(255,0,0),s=state([pageFor(['a'])],[],[]);
 await assert.rejects(writeMagazineExport({state:s,parent,resolveImage:async()=>red}),/missing item/);
 const bad=state([pageFor(['a']),{...pageFor(['b']),number:2}],[{id:'a',photoId:'p',x:150,y:250,width:40},{id:'b',photoId:'q',x:150,y:250,width:40}],[{id:'p',width:20,height:10},{id:'q',width:20,height:10}]);
 await assert.rejects(writeMagazineExport({state:bad,parent,longEdge:2400,resolveImage:async p=>{if(p.id==='q')throw Error('missing source');return red;}}),/missing source/);
 assert.deepEqual(await fs.readdir(parent),[]);
});
