const test=require('node:test'),assert=require('node:assert/strict');
const {cleanAdjustments}=require('../src/film-engine.js');
test('community native controls are opt-in and bounded',()=>{
 const base=cleanAdjustments({engine:'spectral'});
 assert.equal(base.spectralEdge,false);assert.equal(base.spectralDate,false);assert.equal(base.spectralMask,false);
 const a=cleanAdjustments({engine:'spectral',spectralVersion:2,spectralEdge:true,spectralDate:true,spectralDateText:' 2026-10-29 ',spectralMask:true,spectralMaskHighlights:9,spectralMaskShadows:-1});
 assert.equal(a.spectralEdge,true);assert.equal(a.spectralDateText,'2026-10-29');assert.equal(a.spectralMaskHighlights,3);assert.equal(a.spectralMaskShadows,0);
});
test('date imprint rejects impossible or ambiguous dates',()=>{
 for(const value of ['2025-02-29','2026-13-01','2026-04-31','today','2026-10-00'])assert.equal(cleanAdjustments({spectralDateText:value}).spectralDateText,'');
 assert.equal(cleanAdjustments({spectralDateText:'2024-02-29'}).spectralDateText,'2024-02-29');
});
test('native film border is contained without stretching in share output',()=>{
 const {paintPhoto}=require('../src/share-grid.js');let draw;
 const ctx={save(){},restore(){},translate(){},rotate(){},drawImage(...args){draw=args;}};
 paintPhoto(ctx,{x:0,y:0,angle:0,width:600},{width:900,height:600,adjustments:{engine:'spectral',spectralEdge:true}},{width:800,height:740});
 assert(Math.abs(draw[3]/draw[4]-800/740)<1e-10);assert(draw[3]<=600&&draw[4]<=400);
});
