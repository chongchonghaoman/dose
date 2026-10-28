const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {layoutPhotos,reflowPage}=require('../src/editorial-layout.js');
const {cleanState}=require('../src/core.cjs');
const input=n=>Array.from({length:n},(_,i)=>({id:'p'+i,aspect:[.22,.65,1,1.5,3.6][i%5]}));

test('Local reflow keeps paper and membership, responds to aspects and changes the composition',()=>{
  for(const style of ['editorial','moments'])for(const n of [1,7,24,166]){
    const photos=input(n),layout=layoutPhotos(photos,{style,availableWidth:960,origin:{x:-700,y:200},variant:4});
    for(const page of layout.pages){
      const before=structuredClone({photos,page}),local=reflowPage(photos,page);
      assert.deepEqual({photos,page},before,'inputs must not mutate');
      const {composition,variant,seed,...paper}=local.page,{composition:oldFamily,variant:oldVariant,seed:oldSeed,...oldPaper}=page;
      assert.deepEqual(paper,oldPaper);assert.equal(variant,oldVariant+1);assert.notEqual(composition,oldFamily);
      assert.deepEqual(new Set(local.items.map(i=>i.id)),new Set(page.itemIds));
      assert.notDeepEqual(local.items,layout.items.filter(i=>page.itemIds.includes(i.id)));
      for(const p of local.items){
        const h=p.width/photos.find(i=>i.id===p.id).aspect;assert.equal(p.presentation,'print');assert(p.width>0);
        assert(p.x-p.width/2>=page.x-1e-7&&p.x+p.width/2<=page.x+page.width+1e-7);
        assert(p.y-h/2>=page.y-1e-7&&p.y+h/2<=page.y+page.height+1e-7);
        for(const q of local.items)if(p!==q){const qh=q.width/photos.find(i=>i.id===q.id).aspect;assert(Math.abs(p.x-q.x)>=(p.width+q.width)/2-1e-7||Math.abs(p.y-q.y)>=(h+qh)/2-1e-7,'photos must not overlap');}
      }
    }
  }
});

test('Reflow uses stable page membership order and continues exploring after a full round',()=>{
  const photos=input(8),first=layoutPhotos(photos,{style:'editorial'}).pages[0];let page=first;const generations=[];
  for(let n=0;n<14;n++){
    const local=reflowPage(photos,page);assert.deepEqual(local,reflowPage(photos.slice().reverse(),page));
    assert.notEqual(local.page.composition,page.composition);generations.push(JSON.stringify(local.items));page=local.page;
  }
  assert.equal(new Set(generations).size,14);
});

test('Incomplete page inputs cannot produce a partially reflowed page',()=>{
  const photos=input(8),page=layoutPhotos(photos,{style:'editorial'}).pages[0];
  assert.throws(()=>reflowPage(photos.filter(p=>p.id!==page.itemIds[0]),page),RangeError);
  assert.throws(()=>reflowPage(photos,{...page,itemIds:[]}),RangeError);
});

test('Local variant and geometry survive saved-state sanitization without changing grading',()=>{
  const photos=input(24),layout=layoutPhotos(photos,{style:'moments'}),local=reflowPage(photos,layout.pages[4]);
  const map=new Map(local.items.map(p=>[p.id,p]));const state={photos:photos.map(p=>({id:p.id,path:path.resolve(__dirname,p.id+'.jpg'),width:p.aspect*1000,height:1000,adjustments:{exposure:.4,saturation:12}})),items:layout.items.map(p=>({...p,...map.get(p.id),photoId:p.id,layoutSizing:'free'})),editorialPages:layout.pages.map((p,i)=>i===4?local.page:p),layoutStyle:'moments',momentsRevision:3};
  const cleaned=cleanState(state);assert.deepEqual(cleaned.editorialPages[4],local.page);assert.deepEqual(cleanState(cleaned),cleaned);
  assert.equal(cleaned.momentsRevision,3);assert(cleaned.photos.every(p=>p.adjustments.exposure===.4&&p.adjustments.saturation===12));
});
