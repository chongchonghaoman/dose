const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {cleanState}=require('../src/core.cjs');
test('hero and reading roles survive saving and reopening existing layouts',()=>{
  const input={photos:[{id:'photo',path:path.resolve('a.jpg'),width:1500,height:1000}],items:[{id:'item',photoId:'photo',width:600,hero:true,presentation:'print'}],editorialPages:[{x:0,y:0,width:849,height:1200,number:1,role:'opening',heroId:'item',itemIds:['item']}]};
  const saved=cleanState(input),reopened=cleanState(JSON.parse(JSON.stringify(saved)));
  assert.equal(reopened.items[0].hero,true);assert.equal(reopened.editorialPages[0].heroId,'item');assert.equal(reopened.editorialPages[0].role,'opening');
  const legacy=cleanState({...input,items:input.items.map(({hero,...item})=>item),editorialPages:input.editorialPages.map(({role,heroId,...page})=>page)});
  assert.equal(legacy.items[0].hero,false);assert.equal(legacy.editorialPages[0].heroId,null);assert.equal(legacy.items[0].width,600);
});
test('stale hero references cannot survive missing page membership',()=>{
  const saved=cleanState({photos:[{id:'p',path:path.resolve('a.jpg')}],items:[{id:'item',photoId:'p'}],editorialPages:[{itemIds:['item'],heroId:'missing',role:'injected'}]});
  assert.equal(saved.editorialPages[0].heroId,null);assert.equal(saved.editorialPages[0].role,'story');
});
