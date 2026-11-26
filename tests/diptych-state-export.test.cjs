const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const os=require('node:os');
const fs=require('node:fs/promises');
const sharp=require('sharp');
const {cleanState}=require('../src/core.cjs');
const {layoutPairs}=require('../src/diptych-layout.js');
const {sourceRect}=require('../src/crop-geometry.js');
const {writeMagazineExport}=require('../src/magazine-export.cjs');

function scene(){
  const layout=layoutPairs([{ids:['ia','ib'],reason:'相近色彩'}]);
  return {...layout,editorialPages:layout.pages,layoutStyle:'diptych',diptychMode:'couple',photos:[{id:'a',path:path.resolve('a.jpg'),width:400,height:100,pairing:{place:'宇治',person:'a'}},{id:'b',path:path.resolve('b.jpg'),width:100,height:400,pairing:{place:'宇治',person:'b'}}],items:layout.items.map((i,k)=>({...i,photoId:k?'b':'a'}))};
}
test('diptych crop, pairing annotations, white seam and page order survive restart',()=>{
  const initial=scene();initial.items[0].crop={x:.9,y:.2,zoom:1.5};
  const saved=cleanState(initial),again=cleanState(JSON.parse(JSON.stringify(saved)));
  assert.deepEqual(again,saved);assert.equal(again.layoutStyle,'diptych');assert.equal(again.diptychMode,'couple');
  assert.deepEqual(again.photos[0].pairing,{place:'宇治',person:'a'});assert.deepEqual(again.items[0].crop,initial.items[0].crop);
  assert.equal(again.editorialPages[0].kind,'diptych');assert.equal(again.editorialPages[0].height,1500);
  assert.equal(again.items[1].y-again.items[0].y-again.items[0].height,8);
});
test('switching layout removes crop constraints and malformed diptychs cannot export half a pair',()=>{
  const initial=scene();initial.editorialPages[0].kind='magazine';
  assert.equal(cleanState(initial).items[0].crop,undefined);
  initial.editorialPages[0].kind='diptych';initial.items.pop();const cleaned=cleanState(initial);
  assert.equal(cleaned.editorialPages.length,0);assert.equal(cleaned.items[0].crop,undefined);
});
test('cover cropping follows pan and zoom without distorting photo aspect',()=>{
  const left=sourceRect(400,100,1000,746,{x:0,y:.5,zoom:1}),right=sourceRect(400,100,1000,746,{x:1,y:.5,zoom:1});
  assert.equal(left.x,0);assert.equal(left.height,100);assert(Math.abs(left.width/left.height-1000/746)<1e-9);
  assert(Math.abs(right.x+right.width-400)<1e-9);
  const zoomed=sourceRect(400,100,1000,746,{x:1,y:1,zoom:2});assert.equal(zoomed.height,50);assert(zoomed.x>right.x);
});
test('real JPEG/PNG exports match crop, retain 2:3 and white seam with sRGB',async()=>{
  const temp=await fs.mkdtemp(path.join(os.tmpdir(),'dose-diptych-export-'));
  try{
    const red=await sharp({create:{width:100,height:100,channels:3,background:'#ff0000'}}).png().toBuffer();
    const green=await sharp({create:{width:100,height:100,channels:3,background:'#00ff00'}}).png().toBuffer();
    const top=await sharp({create:{width:400,height:100,channels:3,background:'#0000ff'}}).composite([{input:red,left:0,top:0},{input:green,left:300,top:0}]).png().toBuffer();
    const bottom=await sharp({create:{width:100,height:400,channels:3,background:'#ff9900'}}).png().toBuffer();
    const initial=scene();initial.items[0].crop={x:1,y:.5,zoom:2};const state=cleanState(initial),before=JSON.stringify(state);
    for(const format of ['png','jpeg']){
      const out=await writeMagazineExport({state,parent:temp,format,longEdge:2400,resolveImage:async p=>p.id==='a'?top:bottom});
      const meta=await sharp(out.files[0]).metadata();assert.equal(meta.width,1600);assert.equal(meta.height,2400);assert(meta.icc.length>0);
      const pixel=async(x,y)=>[...await sharp(out.files[0]).extract({left:x,top:y,width:1,height:1}).removeAlpha().raw().toBuffer()];
      assert((await pixel(800,1200)).every(v=>v>=250),'white seam');
      const p=await pixel(800,500);assert(p[1]>240&&p[0]<15&&p[2]<15,'pan right shows green source region');
      const b=await pixel(800,1900);assert(b[0]>240&&b[1]>140&&b[1]<170&&b[2]<15,'second photo fills lower slot');
    }
    assert.equal(JSON.stringify(state),before,'export does not mutate session');
  }finally{await fs.rm(temp,{recursive:true,force:true});}
});
