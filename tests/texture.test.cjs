const {test}=require('node:test');
const assert=require('node:assert/strict');
const {applyTexture,cleanAdjustments}=require('../src/film.cjs');

test('texture zero values are byte-identical, including alpha',()=>{
  const src=Buffer.from([12,40,90,7,220,180,100,255]);
  assert.deepEqual(applyTexture(Buffer.from(src),2,1,4,{}),src);
});
test('grain is deterministic and brightness-aware',()=>{
  const src=Buffer.alloc(4*4*3,128), a=Buffer.from(src), b=Buffer.from(src);
  applyTexture(a,4,4,3,{grain:70}); applyTexture(b,4,4,3,{grain:70});
  assert.deepEqual(a,b); assert.notDeepEqual(a,src);
  const dark=Buffer.alloc(300,16), bright=Buffer.alloc(300,240); applyTexture(dark,10,10,3,{grain:100}); applyTexture(bright,10,10,3,{grain:100});
  const spread=x=>Math.max(...x)-Math.min(...x); assert.notEqual(spread(dark),spread(bright));
});
test('halation is spatial and only warms bright edge pixels',()=>{
  const src=Buffer.from([20,20,20, 180,180,180, 20,20,20]);
  const out=Buffer.from(src); applyTexture(out,3,1,3,{halation:100});
  assert(out[0]>src[0] && out[6]>src[6]);
  assert(out[0]-out[1]>0 && out[6]-out[7]>0); // warm halo in dark neighbours
  assert.equal(out[3],src[3]); // highlight core is not strongly dyed
  const far=Buffer.from([20,20,20,20,20,20,20,20,20,180,180,180,20,20,20,20,20,20,20,20,20]);
  const farOut=Buffer.from(far); applyTexture(farOut,7,1,3,{halation:100}); assert.equal(farOut[0],20);
});
test('sanitization bounds texture controls and preserves valid lut id',()=>{
  const id='a'.repeat(64); const a=cleanAdjustments({grain:200,halation:-4,bloom:30,lutId:id});
  assert.equal(a.grain,100); assert.equal(a.halation,0); assert.equal(a.bloom,30); assert.equal(a.lutId,id);
  assert.equal(cleanAdjustments({lutId:'bad'}).lutId,'');
});
test('6000x4000 grain benchmark stays finite without spatial buffers',()=>{
  const width=6000,height=4000, pixels=Buffer.alloc(width*height*3,128), start=Date.now();
  applyTexture(pixels,width,height,3,{grain:35});
  const elapsed=Date.now()-start;
  assert(elapsed<15000,`grain benchmark took ${elapsed}ms`);
});
