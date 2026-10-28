const assert=require('node:assert/strict'),{layoutViewport}=require('../src/viewport-layout.js');
function check(photos,options){
 const before=JSON.stringify(photos),r=layoutViewport(photos,options);assert.equal(JSON.stringify(photos),before);assert.equal(r.items.length,photos.length);assert.deepEqual(r.items.map(p=>p.id),photos.map(p=>p.id));assert.equal(r.pages.length,1);assert.equal(r.pages[0].kind,'viewport');assert.equal(new Set(r.pages[0].itemIds).size,photos.length);
 const boxes=r.items.map((p,i)=>{const src=photos[i],fx=src.frameInsets?.x||0,fy=src.frameInsets?.y||0,w=p.width*(1+2*fx),h=p.width/src.aspect*(1+2*fy);assert(p.width>0&&Number.isFinite(p.width));assert(p.x-w/2>=-1e-7&&p.x+w/2<=options.width+1e-7);assert(p.y-h/2>=-1e-7&&p.y+h/2<=options.height+1e-7);return {x:p.x-w/2,y:p.y-h/2,w,h};});
 for(let i=0;i<Math.min(boxes.length,166);i++)for(let j=0;j<i;j++){const a=boxes[i],b=boxes[j];assert(a.x>=b.x+b.w-1e-7||b.x>=a.x+a.w-1e-7||a.y>=b.y+b.h-1e-7||b.y>=a.y+a.h-1e-7,'frame overlap');}
 return r;
}
for(const n of [1,2,8,31,166])for(const [width,height]of [[1200,400],[600,1000],[800,800]])for(let variant=0;variant<6;variant++)check(Array.from({length:n},(_,id)=>({id,aspect:[.3,.75,1.5,2.5][id%4],frameInsets:{x:id%2?.18:.02,y:id%2?.02:.18}})),{width,height,variant});
const sample=Array.from({length:8},(_,id)=>({id,aspect:[.75,1.5,1.5,1,1.8,2][id%6]}));
const alternatives=Array.from({length:6},(_,variant)=>check(sample,{width:1200,height:500,variant}));assert.equal(new Set(alternatives.map(r=>r.pages[0].composition)).size,6,'window mode uses varied editorial reading paths');
assert.equal(new Set(alternatives.map(r=>JSON.stringify(r.items.map(p=>Math.round(p.width))))).size,6,'window variation changes size hierarchy');
const wide=alternatives[0],tall=check(sample,{width:600,height:1000,composition:wide.pages[0].composition});assert.equal(wide.pages[0].composition,tall.pages[0].composition,'resize can keep the chosen composition family');assert.notDeepEqual(wide.items,tall.items);
const another=check(sample,{width:1200,height:500,variant:0,avoidComposition:wide.pages[0].composition});assert.notEqual(another.pages[0].composition,wide.pages[0].composition,'explicitly changing a resized layout must not repeat the same family');
const many=Array.from({length:5000},(_,id)=>({id,aspect:.4+(id%17)/8})),start=performance.now();check(many,{width:1920,height:1080,variant:0});assert(performance.now()-start<2500,'dense editorial matching must stay bounded');
assert.equal(layoutViewport([],{width:1000,height:500}).items.length,0);console.log('viewport editorial layout tests passed');
