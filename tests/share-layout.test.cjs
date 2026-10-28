const {test}=require('node:test'),assert=require('node:assert/strict');
const {layoutSquare}=require('../src/share-layout.js');
const styles=['editorial','viewport','moments','grid','contact'];
const make=n=>Array.from({length:n},(_,i)=>({id:'p'+i,width:[.22,.65,1,1.5,3.6][i%5]*1000,height:1000}));
const near=(a,b)=>Math.abs(a-b)<1e-6;
function boxesOf(input,result){const source=new Map(input.map(p=>[p.id,p]));return result.items.map(i=>{const p=source.get(i.photoId),h=i.width*p.height/p.width;return {id:i.id,x:i.x-i.width/2,y:i.y-h/2,w:i.width,h};});}
function check(input,r){
 assert.equal(r.bounds.width,2400);assert.equal(r.bounds.height,2400);assert.equal(r.items.length,input.length);assert.equal(new Set(r.items.map(i=>i.id)).size,input.length);assert.deepEqual(new Set(r.items.map(i=>i.photoId)),new Set(input.map(p=>p.id)));
 const boxes=boxesOf(input,r);
 for(const b of boxes){assert(b.w>0&&b.h>0&&Number.isFinite(b.x)&&Number.isFinite(b.y));assert(b.x>=-1e-6&&b.x+b.w<=2400+1e-6&&b.y>=-1e-6&&b.y+b.h<=2400+1e-6,'all four photo edges must stay inside square');}
 // A sweep tests EVERY pair which could overlap, including dense libraries.
 const sorted=boxes.slice().sort((a,b)=>a.x-b.x);let active=[];
 for(const b of sorted){active=active.filter(a=>a.x+a.w>b.x+1e-6);for(const a of active)assert(a.y+a.h<=b.y+1e-6||b.y+b.h<=a.y+1e-6,'photo overlap '+a.id+'/'+b.id);active.push(b);}
 return boxes;
}

function verifyBands(input,result){
 const photoMap=new Map(input.map(p=>[p.id,p])),items=new Map(result.items.map(i=>[i.id,i])),used=new Set();
 for(const region of result.grids){
  const g=region.grid;assert.equal(g.kind,'justified');assert.equal(g.version,2);assert(['rows','columns'].includes(g.axis));let last=null;
  for(const band of g.bands){
   if(last){const gap=g.axis==='rows'?band.y-last.y-last.height:band.x-last.x-last.width;assert(near(gap,g.gap),'bands must use the same gutter');}
   let previous=null;
   for(const id of band.itemIds){assert(!used.has(id));used.add(id);const i=items.get(id),p=photoMap.get(i.photoId),h=i.width*p.height/p.width,left=i.x-i.width/2,top=i.y-h/2;
    assert(left>=region.x-1e-6&&top>=region.y-1e-6&&left+i.width<=region.x+region.width+1e-6&&top+h<=region.y+region.height+1e-6);
    if(g.axis==='rows'){assert(near(h,band.height)&&near(top,band.y));assert(near(previous?left-previous.x-previous.w:left-band.x,previous?g.gap:0));previous={x:left,w:i.width};}
    else{assert(near(i.width,band.width)&&near(left,band.x));assert(near(previous?top-previous.y-previous.h:top-band.y,previous?g.gap:0));previous={y:top,h};}
   }
   assert(near(g.axis==='rows'?previous.x+previous.w:previous.y+previous.h,g.axis==='rows'?band.x+band.width:band.y+band.height));last=band;
  }
 }
 assert.equal(used.size,input.length);
}
test('All five layouts recompose whole libraries inside one fixed square, without mutation or crop',()=>{
 for(const style of styles)for(const n of [1,8,24,166,5000]){const input=make(n),before=structuredClone(input),r=layoutSquare(input,{style,variant:2,edge:2400});check(input,r);assert.deepEqual(input,before);}
});
test('Every actual photo follows its justified row/column module and uniform gutter',()=>{
 for(const style of styles)for(const n of [1,8,24,166])for(const variant of [0,1,6]){
  const input=make(n),r=layoutSquare(input,{style,variant,edge:2400});check(input,r);verifyBands(input,r);
  if(style==='moments'&&n>=9){assert.equal(r.grids.length,9);const counts=r.grids.map(g=>g.grid.bands.reduce((n,b)=>n+b.itemIds.length,0));assert(Math.max(...counts)-Math.min(...counts)<=1);}
 }
});
test('Grid uses shared-height rows and contact uses shared-width columns',()=>{
 for(const style of ['grid','contact'])for(const n of [8,24,166,5000]){const input=make(n),r=layoutSquare(input,{style});verifyBands(input,r);assert(r.grids.every(g=>g.grid.axis===(style==='grid'?'rows':'columns')));}
});
test('Every layout has deterministic geometry and meaningful variant changes',()=>{
 for(const style of styles)for(const n of [8,24,166]){const p=make(n),a=layoutSquare(p,{style,variant:0}),b=layoutSquare(p,{style,variant:1});assert.deepEqual(a,layoutSquare(p,{style,variant:0}));assert.notDeepEqual(a.items,b.items,style+' must actually reflow');}
});
test('Empty and repeated photo inputs do not generate empty entries or duplicate photo instances',()=>{
 assert.deepEqual(layoutSquare([]).items,[]);const p=make(8);check(p,layoutSquare([...p,p[0],p[1]]));
});
const typical=()=>[...Array(58).fill(2/3),...Array(43).fill(1.5),...Array(28).fill(.75),...Array(19).fill(4/3),...Array.from({length:18},(_,i)=>[.8,1.25,1.3585,1.7778][i%4])].map((a,i)=>({id:'t'+i,width:a*1200,height:1200}));
test('Dense 166-photo compositions fill the nine tiles and keep photographs readable',()=>{
 for(const style of styles)for(let variant=0;variant<6;variant++){
  const r=layoutSquare(typical(),{style,variant}),m=r.metrics;
  assert(m.coverage>=.73,style+' image area coverage '+m.coverage);
  assert(Math.min(...m.tileCoverage)>=.64,style+' sparse tile '+Math.min(...m.tileCoverage));
  assert(m.tileSpread<=.23,style+' uneven tile occupancy '+m.tileSpread);
  assert(m.maxToMedianArea<=3,style+' oversized hero '+m.maxToMedianArea);
  assert(m.medianLongEdge>=170,style+' photographs are too small');
 }
});
test('A single portrait cannot absorb the area allocated to a large library',()=>{
 const photos=Array.from({length:166},(_,i)=>({id:'h'+i,width:(i?1.5:2/3)*1200,height:1200}));
 for(const style of styles)for(const variant of [0,1,2,5]){const m=layoutSquare(photos,{style,variant}).metrics;assert(m.maxToMedianArea<=3,'hero imbalance');assert(m.coverage>=.7);}
});
test('Tile occupancy accounts for the actual full-photo rectangles',()=>{
 const r=layoutSquare(typical(),{}),m=r.metrics;assert(near(m.tileCoverage.reduce((a,b)=>a+b,0)/9,m.coverage));assert(m.medianArea>0&&m.medianLongEdge>0);
});
