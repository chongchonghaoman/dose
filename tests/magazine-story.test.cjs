const {test}=require('node:test'),assert=require('node:assert/strict');
const {layoutPhotos,reflowPage}=require('../src/editorial-layout.js');
const photos=n=>Array.from({length:n},(_,i)=>({id:'p'+i,aspect:[.22,.65,1,1.5,3.6][i%5]}));
function geometry(input,layout){
 const originals=new Map(input.map(p=>[p.id,p])),byId=new Map(layout.items.map(i=>[i.id,i]));
 for(const page of layout.pages){
  const members=page.itemIds.map(id=>({...byId.get(id),aspect:originals.get(id).aspect}));
  for(const item of members){const h=item.width/item.aspect;
   assert(item.width>0&&Number.isFinite(item.x));assert(item.x-item.width/2>=page.x-1e-7);assert(item.x+item.width/2<=page.x+page.width+1e-7);
   assert(item.y-h/2>=page.y-1e-7);assert(item.y+h/2<=page.y+page.height+1e-7);
   for(const other of members)if(item!==other)assert(Math.abs(item.x-other.x)>=(item.width+other.width)/2-1e-7||Math.abs(item.y-other.y)>=(h+other.width/other.aspect)/2-1e-7,'photos overlap');
  }
  if(page.heroId&&members.length>1){const hero=members.find(i=>i.id===page.heroId),area=hero.width**2/hero.aspect;assert(members.every(i=>i.id===hero.id||area>=i.width**2/i.aspect*1.6),'main photo must dominate actual image area');}
 }
}
test('books preserve every photo in order and alternate sparse and grouped pages',()=>{
 for(const n of [...Array.from({length:50},(_,i)=>i+1),122,5000]){
  const input=photos(n),r=layoutPhotos(input,{style:'editorial'});
  assert.equal(r.items.length,n);assert.deepEqual(r.pages.flatMap(p=>p.itemIds),input.map(p=>p.id));
  if(n>=5){assert.equal(r.pages[0].itemIds.length,1);assert.equal(r.pages.at(-1).itemIds.length,1);assert(r.pages.some(p=>p.itemIds.length>1));}
 }
 assert.equal(layoutPhotos(photos(6),{}).pages.length,3);assert.equal(layoutPhotos(photos(12),{}).pages.length,6);
});
test('main photo remains largest across proportions, variants and local reflow',()=>{
 for(const aspect of [.22,.65,1,1.5,3.6])for(let variant=0;variant<6;variant++){
  const input=photos(6);input[3]={...input[3],aspect,hero:true};
  const r=layoutPhotos(input,{availableWidth:960,variant});geometry(input,r);
  const page=r.pages.find(p=>p.itemIds.includes(input[3].id));assert.equal(page.heroId,input[3].id);
  const local=reflowPage(input,page);assert.deepEqual(local.page.itemIds,page.itemIds);assert.equal(local.page.role,page.role);assert.equal(local.page.heroId,page.heroId);
  geometry(input,{items:local.items,pages:[local.page]});assert.deepEqual(reflowPage(input.slice().reverse(),page),local);
 }
});
test('the nine-page mode keeps its page count while using varied density and heroes',()=>{
 for(const n of [1,4,9,12,24,122]){
  const input=photos(n);if(n>12)input[Math.floor(n/2)].hero=true;
  const r=layoutPhotos(input,{style:'moments'});assert.equal(r.pages.length,Math.min(9,n));
  assert.deepEqual(r.pages.flatMap(p=>p.itemIds),input.map(p=>p.id));geometry(input,r);
 }
});
test('saved variants are deterministic and do not mutate input',()=>{
 const input=photos(12);input[4].hero=true;const before=JSON.stringify(input),a=layoutPhotos(input,{variant:3});
 assert.equal(JSON.stringify(input),before);assert.deepEqual(a,layoutPhotos(input,{variant:3}));assert.notDeepEqual(a.items,layoutPhotos(input,{variant:4}).items);
});
