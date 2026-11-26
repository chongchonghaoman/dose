const {test}=require('node:test'),assert=require('node:assert/strict');
const {pairPhotos,layoutPairs}=require('../src/diptych-layout.js');
const color=(h,saturation=.7)=>({histogram:Array.from({length:12},(_,i)=>i===h?1:0),saturation,lightness:.5});
test('red and blue do not pair, neighboring reds wrap across the hue origin',()=>{
  assert.equal(pairPhotos([{id:'red',color:color(0)},{id:'blue',color:color(8)}],{mode:'color'}).pairs.length,0);
  assert.equal(pairPhotos([{id:'red1',color:color(11)},{id:'red2',color:color(0)}],{mode:'color'}).pairs.length,1);
  assert.equal(pairPhotos([{id:'gray',color:color(0,0)},{id:'red',color:color(0)}],{mode:'color'}).pairs.length,0);
});
test('real location pairs without color; capture time alone is not location',()=>{
  const gps={latitude:35,longitude:135};
  assert.equal(pairPhotos([{id:'a',gps},{id:'b',gps}],{mode:'related'}).pairs.length,1);
  assert.equal(pairPhotos([{id:'a',capturedAt:123},{id:'b',capturedAt:123}],{mode:'place'}).pairs.length,0);
  const r=pairPhotos([{id:'a',place:' 宇治 '},{id:'b',place:'宇治'}]);assert.equal(r.pairs[0].reason,'同一地点');
});
test('couple mode pairs each A with B even when imports are grouped separately',()=>{
  const photos=['a','b'].flatMap(person=>Array.from({length:300},(_,i)=>({id:person+i,person}))),r=pairPhotos(photos,{mode:'couple'});
  assert.equal(r.pairs.length,300);assert(r.pairs.every(p=>p.ids[0].startsWith('a')&&p.ids[1].startsWith('b')));
  assert.equal(new Set(r.pairs.flatMap(p=>p.ids)).size,600);
});
test('manual order, duplicate IDs, odd counts and unrelated leftovers stay explicit',()=>{
  const photos=[{id:'c'},{id:'a'},{id:'b'},{id:'a'}],r=pairPhotos(photos,{mode:'manual'});
  assert.deepEqual(r.pairs[0].ids,['c','a']);assert.deepEqual(r.unpaired,['b']);
  const none=pairPhotos(photos);assert.deepEqual(none.unpaired,['c','a','b']);assert.equal(none.pairs.length,0);
});
test('color chooses a closer match instead of an earlier unrelated candidate',()=>{
  const r=pairPhotos([{id:'red',color:color(0)},{id:'blue',color:color(8)},{id:'red2',color:color(0)},{id:'blue2',color:color(8)}],{mode:'color'});
  assert.deepEqual(r.pairs.map(p=>p.ids),[['red','red2'],['blue','blue2']]);
});
test('fixed slots fill a 2:3 page with an 8px seam at width1000; malformed pairs skipped',()=>{
  const r=layoutPairs([{ids:['a','b'],reason:'手动配对'},{ids:['c','d']},{ids:['a','a']}]);
  assert.equal(r.pages.length,2);assert.equal(r.pages[0].width/r.pages[0].height,2/3);
  assert.equal(r.items[0].height,746);assert.equal(r.items[1].y-r.items[0].y,754);
  assert.equal(r.pages[1].x,1032);assert(r.items.every(i=>i.crop.x===.5&&i.crop.zoom===1));
});
test('large color libraries retain all IDs within practical bounded matching',()=>{
  const photos=Array.from({length:5000},(_,i)=>({id:String(i),color:color(i%12)})),start=performance.now(),r=pairPhotos(photos,{mode:'color'});
  assert.equal(new Set([...r.pairs.flatMap(p=>p.ids),...r.unpaired]).size,5000);
  assert(performance.now()-start<8000);
});
