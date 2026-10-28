const test=require('node:test'),assert=require('node:assert/strict');
const {naturalDefaults,spectralDefaults,cleanAdjustments,withSpectralIntent}=require('../src/film.cjs');
test('Saved recipes retain original intent; natural is explicit and suppresses competing adaptation',()=>{
 const old={...spectralDefaults(),exposure:.7,highlights:-27,grain:9};
 const cleaned=cleanAdjustments(old);assert.equal(cleaned.spectralIntent,'original');assert.equal(cleaned.exposure,.7);assert.equal(cleaned.highlights,-27);
 const natural=cleanAdjustments({...naturalDefaults(),autoFitMode:'natural',autoFitVersion:2,autoFitEV:.7});
 assert.equal(natural.autoFitMode,'off');assert.equal(natural.autoFitEV,0);
 const changed=withSpectralIntent(old,'natural');assert.equal(changed.grain,9);assert.equal(changed.highlights,-27);assert.equal(changed.exposure,.7);assert.equal(changed.spectralPaper,old.spectralPaper);
 assert.equal(old.spectralIntent,undefined);assert.equal(withSpectralIntent(changed,'original').spectralIntent,'original');
});
