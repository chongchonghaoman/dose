const assert = require('node:assert/strict');
const { layoutPhotos } = require('../src/editorial-layout.js');

function check(mode, n,variant=0) {
  const input = Array.from({ length: n }, (_, i) => ({ id: `p${i}`, aspect: [0.22, 0.55, 1, 1.8, 3.6][i % 5], frameInsets: { x: 0.08, y: 0.04 }, width: 100 + i }));
  const before = JSON.stringify(input), result = layoutPhotos(input, { style: mode, origin: { x: 30, y: 40 }, availableWidth: 960, gap: 16,variant });
  assert.equal(result.items.length, n);
  assert.equal(JSON.stringify(input), before);
  assert.ok(result.bounds.width > 0 && result.bounds.height >= 0);
  for (const p of result.items) assert.ok(Number.isFinite(p.x) && Number.isFinite(p.y) && p.width > 0);
  for (let i = 0; i < result.items.length; i++) for (let j = i + 1; j < result.items.length; j++) {
    const a = result.items[i], b = result.items[j], ai = a.presentation==='print'?{x:0,y:0}:input[i].frameInsets, bi = b.presentation==='print'?{x:0,y:0}:input[j].frameInsets;
    const aw = a.width * (1 + 2 * ai.x), bw = b.width * (1 + 2 * bi.x);
    const ah = a.width / input[i].aspect * (1 + 2 * ai.y), bh = b.width / input[j].aspect * (1 + 2 * bi.y);
    assert.ok(Math.abs(a.x - b.x) >= (aw + bw) / 2 - 1e-7 || Math.abs(a.y - b.y) >= (ah + bh) / 2 - 1e-7, `${mode} overlap ${i}/${j}`);
  }
  for (let i = 0; i < n; i++) assert.ok(result.items[i].width > 0 && input[i].aspect > 0);
}
for (const mode of ['editorial', 'grid', 'contact']) for (const n of [1, 2, 3, 4, 6, 12, 30]) check(mode, n);
const editorial12 = layoutPhotos(Array.from({ length: 12 }, (_, i) => ({ id: i, aspect: 1.2, frameInsets: { x: 0.1, y: 0.05 } })), { style: 'editorial', availableWidth: 960, gap: 16 });
assert.ok(editorial12.bounds.height < 3200, 'a six-page story should remain a manageable canvas');
assert.equal(editorial12.pages.length,6);
assert(editorial12.items.every(p=>p.presentation==='print'));
const photos=[.7,1.5,1.5,1,2,1.5,1.5,1.8].map((aspect,id)=>({id,aspect})),variations=Array.from({length:7},(_,variant)=>layoutPhotos(photos,{style:'editorial',availableWidth:849,variant}));
assert(variations.every(r=>r.pages[0].height===1200&&r.pages[0].width===849));
assert.equal(new Set(variations.slice(0,6).map(r=>r.pages[0].composition)).size,6,'same photographs must have different reading-path families');
const shape=r=>JSON.stringify(r.items.map((p,i)=>[Math.round(p.width),Math.round(p.width/photos[i].aspect)]).sort((a,b)=>a[0]-b[0]));
assert.equal(new Set(variations.slice(0,6).map(shape)).size,6,'size hierarchies must differ, not only position or image ordering');
assert.notDeepEqual(variations[0].items,variations[6].items,'after a full round explore new proportions');
assert.deepEqual(layoutPhotos(photos,{style:'editorial',availableWidth:849,variant:0}),variations[0],'stored seed/variant gives stable composition');
const portrait=layoutPhotos(photos.map(p=>({...p,aspect:.6})),{}),landscape=layoutPhotos(photos.map(p=>({...p,aspect:2.2})),{});
assert.notDeepEqual(portrait.items.map(p=>p.width),landscape.items.map(p=>p.width),'proportions respond to source aspect ratios');
for(let variant=0;variant<12;variant++)for(const n of [1,2,3,4,6,7,8,9,16,30,166]){
  check('editorial',n,variant);
  const items=Array.from({length:n},(_,id)=>({id,aspect:[.22,.75,1.5,2.5][id%4]})),result=layoutPhotos(items,{style:'editorial',variant}),ids=result.pages.flatMap(p=>p.itemIds);assert.equal(new Set(ids).size,n);assert.equal(ids.length,n);
  for(const [index,page]of result.pages.entries()){assert(page.itemIds.length<=8);if(index)assert.notEqual(page.composition,result.pages[index-1].composition,'neighbouring pages must differ');for(const id of page.itemIds){const p=result.items[id],h=p.width/items[id].aspect;assert(p.x-p.width/2>=page.x-1e-8&&p.x+p.width/2<=page.x+page.width+1e-8);assert(p.y-h/2>=page.y-1e-8&&p.y+h/2<=page.y+page.height);}}
}
assert.deepEqual(layoutPhotos([], { style: 'editorial' }), { items: [],pages:[], bounds: { x: 0, y: 0, width: 1000, height: 0 } });
console.log('editorial-layout tests passed');
