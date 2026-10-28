const assert=require('node:assert/strict'),path=require('node:path');
const {layoutPhotos}=require('../src/editorial-layout.js'),{cleanState}=require('../src/core.cjs');
const input=n=>Array.from({length:n},(_,id)=>({id:'p'+id,aspect:[.22,.55,1,1.8,3.6][id%5]}));
function check(n,variant=0){
 const photos=input(n),before=JSON.stringify(photos),result=layoutPhotos(photos,{style:'moments',availableWidth:1000,variant}),pages=result.pages;
 assert.equal(pages.length,Math.min(9,n));assert.equal(result.items.length,n);assert.equal(JSON.stringify(photos),before);
 const ids=pages.flatMap(p=>p.itemIds);assert.equal(ids.length,n);assert.equal(new Set(ids).size,n);
 const byId=new Map(result.items.map((p,i)=>[p.id,{...p,h:p.width/photos[i].aspect}]));
 if(n>10){const counts=pages.map(p=>p.itemIds.length);assert(Math.max(...counts)>Math.min(...counts),'a fixed page count still needs changes in density');}
 for(const [index,page]of pages.entries()){
  assert.equal(page.kind,'moments');assert.equal(page.number,index+1);assert.equal(page.width,1000);assert(Math.abs(page.height/page.width-1200/849)<1e-10);
  if(index)assert.notEqual(page.composition,pages[index-1].composition);
  const batch=page.itemIds.map(id=>byId.get(id));
  for(const p of batch){assert(p.width>0&&Number.isFinite(p.x)&&Number.isFinite(p.y));assert.equal(p.presentation,'print');assert(p.x-p.width/2>=page.x-1e-8&&p.x+p.width/2<=page.x+page.width+1e-8);assert(p.y-p.h/2>=page.y-1e-8&&p.y+p.h/2<=page.y+page.height+1e-8);}
  for(let i=0;i<batch.length;i++)for(let j=i+1;j<batch.length;j++){const a=batch[i],b=batch[j];assert(Math.abs(a.x-b.x)>=(a.width+b.width)/2-1e-7||Math.abs(a.y-b.y)>=(a.h+b.h)/2-1e-7,'Photos overlap');}
 }
 if(n>=9){assert.equal(new Set(pages.map(p=>p.x)).size,3);assert.equal(new Set(pages.map(p=>p.y)).size,3);}
 return result;
}
for(const variant of [0,1,6])for(const n of [0,1,4,8,9,10,17,73,166])check(n,variant);
check(5000);
const photos=input(166),first=check(166),second=check(166,1);assert.notDeepEqual(first.items,second.items);assert.deepEqual(layoutPhotos(photos,{style:'moments',availableWidth:1000,variant:0}),first);
const cleaned=cleanState({photos:photos.map(p=>({id:p.id,path:path.resolve(__dirname,p.id+'.jpg'),width:p.aspect*1000,height:1000,adjustments:{exposure:.4,saturation:12}})),items:first.items.map(p=>({...p,photoId:p.id,layoutSizing:'free'})),editorialPages:first.pages,layoutStyle:'moments',momentsRevision:7});
assert.equal(cleaned.layoutStyle,'moments');assert.equal(cleaned.momentsRevision,7);assert.equal(cleaned.editorialPages.length,9);assert(cleaned.editorialPages.every(p=>p.kind==='moments'));assert(cleaned.photos.every(p=>p.adjustments.exposure===.4&&p.adjustments.saturation===12));assert.deepEqual(cleanState(cleaned),cleaned);
assert.equal(layoutPhotos(photos,{style:'editorial'}).pages.length,43,'Ordinary magazine gives the opening and closing their own page');
console.log('Moments: nine paced pages, 3x3 ordering, full coverage through 5000 photos, variation and persistence passed');
