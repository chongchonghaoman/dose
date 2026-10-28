const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {cleanState,supported}=require('../src/core.cjs');
test('layout recovery discards invalid references and bounds hostile numeric values',()=>{
  const s=cleanState({photos:[{id:'ok',path:path.resolve('photo.jpg'),width:4000,height:3000},{id:'bad',path:'relative.jpg'}],items:[{id:'a',photoId:'ok',x:Infinity,width:-2,angle:NaN},{id:'orphan',photoId:'gone'}],camera:{zoom:Infinity},brightness:99});
  assert.equal(s.photos.length,1);assert.equal(s.items.length,1);assert.equal(s.items[0].x,0);assert.equal(s.items[0].width,60);assert.equal(s.camera.zoom,1);assert.equal(s.brightness,1.6);
});
test('local image allowlist excludes executable and active document formats',()=>{
  for(const p of ['a.JPG','a.tiff','a.avif','a.webp'])assert.equal(supported(p),true);
  for(const p of ['a.exe','a.svg','a.html','a.jpg.exe'])assert.equal(supported(p),false);
});
test('empty and corrupt state normalize without throwing',()=>{
  for(const x of [null,undefined,17,'bad',{}, {photos:[null],items:[null]}])assert.deepEqual(cleanState(x).photos,[]);
});
test('magazine pages preserve print geometry and reject invalid or repeated membership',()=>{
  const photo={id:'p',path:path.resolve('photo.jpg'),width:4000,height:3000};
  const s=cleanState({photos:[photo],items:[{id:'a',photoId:'p',presentation:'print',width:45},{id:'b',photoId:'p'}],editorialPages:[{x:NaN,width:Infinity,height:1400,itemIds:['a','missing','a']},{itemIds:['a','b']},null,{itemIds:['missing']}]});
  assert.equal(s.items[0].width,45);assert.equal(s.items[0].presentation,'print');assert.equal(s.items[1].presentation,'print');assert.equal(s.editorialPages[0].x,0);assert.equal(s.editorialPages[0].width,1000);assert.deepEqual(s.editorialPages.map(p=>p.itemIds),[['a'],['b']]);
  assert.equal(cleanState({photos:[photo],items:[{id:'c',photoId:'p',mount:'slide'}]}).items[0].presentation,'film');
  assert.deepEqual(cleanState(s),s);
});
test('adaptive variants and dense viewport widths survive save/load without clamping to film thumbnails',()=>{
  const s=cleanState({photos:[{id:'p',path:path.resolve('photo.jpg')}],items:[{id:'a',photoId:'p',width:17,layoutSizing:'viewport'}],layoutStyle:'viewport',editorialRevision:9,editorialPages:[{itemIds:['a'],composition:'columns',variant:8,seed:1234}]});
  assert.equal(s.items[0].width,17);assert.equal(s.items[0].layoutSizing,'viewport');assert.equal(s.layoutStyle,'viewport');assert.equal(s.editorialRevision,9);assert.equal(s.editorialPages[0].composition,'columns');assert.equal(s.editorialPages[0].variant,8);
  assert.equal(cleanState({...s,layoutStyle:'grid'}).items[0].width,17,'changing a mode selector without relayout must not enlarge unrelated saved photos');assert.deepEqual(cleanState(s),s);
  const dense=cleanState({...s,viewportRevision:7,items:[{...s.items[0],width:1e-6}],editorialPages:[{...s.editorialPages[0],kind:'viewport',height:60}]});assert.equal(dense.items[0].width,1e-6);assert.equal(dense.editorialPages[0].height,60);assert.equal(dense.viewportRevision,7);
});
