const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {layoutPhotos,layoutViewport,reflowPage,gridSpec}=require('../src/editorial-layout.js'),{cleanState}=require('../src/core.cjs');
const near=(a,b)=>Math.abs(a-b)<1e-6;
function verify(input,result,framed=false){
 const originals=new Map(input.map(p=>[p.id,p])),placed=new Map(result.items.map(p=>[p.id,p]));
 for(const page of result.pages){
  assert.equal(page.grid.columns,12);assert.equal(page.grid.version,1);const d=page.grid.subdivisions,g=gridSpec(page.width,page.height,d),parent=gridSpec(page.width,page.height,1);
  for(let c=0;c<12;c++){assert(near(g.lefts[c*d],parent.lefts[c]));assert(near(g.rights[(c+1)*d-1],parent.rights[c]));}
  for(let c=1;c<g.lefts.length;c++)assert(near(g.lefts[c]-g.rights[c-1],c%d===0?g.parentGutter:g.gutter),'gutters must follow the parent/subcolumn system');
  for(const id of page.itemIds){const p=placed.get(id),src=originals.get(id),ix=framed?(src.frameInsets?.x||0):0,iy=framed?(src.frameInsets?.y||0):0,w=p.width*(1+2*ix),h=p.width/src.aspect*(1+2*iy),left=p.x-w/2-page.x,right=p.x+w/2-page.x,top=p.y-h/2-page.y;
   assert(g.lefts.some(x=>near(x,left)),id+' left edge must sit on a column');assert(g.rights.some(x=>near(x,right)),id+' right edge must sit on a column');
   const row=(top-g.top)/g.baseline;assert(near(row,Math.round(row)),id+' actual photo top must sit on a baseline');
   assert(top>=g.top-1e-6&&top+h<=g.top+g.rows*g.baseline+1e-6);assert(Number.isFinite(p.width)&&p.width>0);
  }
 }
}
test('Actual photo edges and tops obey the same grid in every editorial composition',()=>{
 for(const n of [1,2,3,7,8,9,17,73,166])for(let variant=0;variant<12;variant++){
  const photos=Array.from({length:n},(_,id)=>({id:'p'+id,aspect:[.22,.65,1,1.5,3.6][id%5]}));
  for(const style of ['editorial','moments'])verify(photos,layoutPhotos(photos,{style,origin:{x:-350,y:117},availableWidth:960,variant}));
 }
});
test('Window compositions align actual frame edges on wide and tall screens, through dense libraries',()=>{
 for(const n of [8,166,5000])for(const [width,height]of [[1200,400],[600,1000]])for(const variant of [0,1,6]){
  const photos=Array.from({length:n},(_,id)=>({id,aspect:[.3,.75,1.5,2.5][id%4],frameInsets:{x:id%2?.18:.02,y:id%2?.02:.18}}));
  verify(photos,layoutViewport(photos,{width,height,variant}),true);
 }
});
test('Local reflow and save/load retain the grid contract with full uncropped photo proportions',()=>{
 const photos=Array.from({length:24},(_,id)=>({id:'p'+id,aspect:[.7,1.5,1,2][id%4]})),layout=layoutPhotos(photos,{style:'moments',availableWidth:960}),local=reflowPage(photos,layout.pages[4]);
 verify(photos,{items:local.items,pages:[local.page]});
 const cleaned=cleanState({photos:photos.map(p=>({...p,path:path.resolve(__dirname,p.id+'.jpg'),width:p.aspect*1000,height:1000})),items:layout.items.map(p=>({...p,photoId:p.id})),editorialPages:layout.pages});
 assert.deepEqual(cleaned.editorialPages.map(p=>p.grid),layout.pages.map(p=>p.grid));assert.deepEqual(cleanState(cleaned),cleaned);
});
