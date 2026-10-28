const {test}=require('node:test'),assert=require('node:assert/strict');
const E=require('../src/editorial-layout.js'),S=require('../src/share-layout.js');
const near=(a,b)=>Math.abs(a-b)<1e-6;

test('A normal mixed photo story uses the paper and has distinct scale hierarchies',()=>{
 const photos=[1.5,1.5,2/3,1.5,1.5,1.5,.75,1.5].map((aspect,id)=>({id,aspect})),result=[];
 for(let variant=0;variant<6;variant++){
  const r=E.layoutPhotos(photos,{style:'editorial',availableWidth:849,variant}),areas=r.items.map((p,i)=>p.width*p.width/photos[i].aspect).sort((a,b)=>a-b);
  result.push({coverage:areas.reduce((a,b)=>a+b,0)/(849*1200),ratio:areas.at(-1)/areas[4]});
  assert(Math.min(...r.items.map((p,i)=>p.y-p.width/photos[i].aspect/2))<=120,'no empty 16% title block');
 }
 assert(result[0].coverage>=.48,'default must give the photographs enough area');
 assert(result.some(r=>r.ratio>=2),'a reading-path family must establish a clear main photograph');
 assert(result.every(r=>r.ratio<=6),'secondary photographs must remain readable');
});

test('Editorial square groups use shared twelve-column rails and keep chronological neighbourhoods',()=>{
 for(const n of [24,122,166])for(let variant=0;variant<6;variant++){
  const photos=Array.from({length:n},(_,i)=>({id:'p'+i,width:[2/3,1.5,.75,4/3][i%4]*1200,height:1200})),r=S.layoutSquare(photos,{style:'editorial',variant});
  const margin=2400*.012,gutter=2400*.009,unit=(2400-2*margin+gutter)/12;
  assert(r.grids.length>=3,'editorial needs articulated groups');
  for(const region of r.grids){
   for(const v of [(region.x-margin)/unit,(region.y-margin)/unit,(region.width+gutter)/unit,(region.height+gutter)/unit])assert(near(v,Math.round(v)),'module boundary must sit on a shared rail');
   const indices=region.grid.bands.flatMap(b=>b.itemIds).map(id=>Number(id.replace('share-p',''))).sort((a,b)=>a-b);
   assert.equal(indices.at(-1)-indices[0]+1,indices.length,'a photo group must not interleave the entire library');
  }
  if(n>=122){assert(r.metrics.coverage>=.70);assert(Math.min(...r.metrics.tileCoverage)>=.58);assert(r.metrics.maxToMedianArea<=3);}
 }
});

test('Single-photo pages give the photograph a substantial area without losing aspect ratio',()=>{
 for(const aspect of [2/3,.75,1,1.5]){
  const r=E.layoutPhotos([{id:'one',aspect}],{style:'editorial',availableWidth:849});
  assert(r.items[0].width>=500);assert(r.items[0].width/aspect<=1200);assert.equal(r.pages[0].itemIds[0],'one');
 }
});
