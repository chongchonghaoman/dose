const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp'),{Worker}=require('node:worker_threads');
const Fit=require('../src/auto-fit.js'),{LutLibrary}=require('../src/lut-library.cjs'),{SpectralHost}=require('../src/spectral-client.cjs'),Film=require('../src/film.cjs');
const root=path.resolve(__dirname,'../../..'),version=require('../package.json').version,out=path.join(root,'outputs/v'+version+'/verification');
(async()=>{await fs.mkdir(out,{recursive:true});const worker=new Worker(path.join(__dirname,'../src/film-worker.cjs')),pending=new Map();let seq=0;worker.on('message',r=>{const p=pending.get(r.id);if(!p)return;pending.delete(r.id);r.error?p.reject(Error(r.error)):p.resolve(r.result);});worker.on('error',e=>{for(const p of pending.values())p.reject(e);pending.clear();});function job(q){return new Promise((resolve,reject)=>{const id=++seq;pending.set(id,{resolve,reject});worker.postMessage({...q,id});});}
const h=new SpectralHost(),old=new SpectralHost({home:path.join(root,'outputs/v0.12.0/dose-win32-x64/resources/spectral')}),checks=[],cases=[];
try{
 const lib=new LutLibrary(path.join(out,'fixture-lut-library'),path.join(__dirname,'../assets/luts'));await lib.load();const library=lib.status().library;
 const file=path.join(__dirname,'fixtures/01-valley.jpg'),src=await sharp(file).rotate().resize(320,320,{fit:'inside'}).ensureAlpha().raw().toBuffer({resolveWithObject:true});
 for(const lut of library){
   const resolved=lib.resolve(lut.hash),cube=Film.parseCube(await fs.readFile(resolved.path,'utf8')),a={...Film.DEFAULTS,lut:true,lutId:lut.hash},before=Buffer.from(src.data);Film.applyPixels(before,4,a,cube);
   const fit=await job({kind:'auto-fit',input:file,referenceInput:file,adjustments:a,lutPath:resolved.path}),after=Buffer.from(src.data);Film.applyPixels(after,4,{...a,autoFitMode:'natural',autoFitEV:fit.ev,autoFitSaturation:fit.saturation},cube);
   const s=Fit.measure(src.data),b=Fit.measure(before),c=Fit.measure(after);
   assert(fit.ev>=0&&fit.ev<=.75);assert.equal(fit.saturation,1);assert(Fit.safeBrightness(b,c),lut.name+' tone safety');
   assert(c.p50>=b.p50-.002,lut.name+' must not darken');
   cases.push({engine:'lut',name:lut.name,ev:fit.ev,saturation:fit.saturation,sourceLuma:s.luminance,beforeLuma:b.luminance,afterLuma:c.luminance,sourceChroma:s.chroma,beforeChroma:b.chroma,afterChroma:c.chroma});
   if(cases.length===1){await sharp(before,{raw:{...src.info,channels:4}}).png().toFile(path.join(out,'lut-fit-before.png'));await sharp(after,{raw:{...src.info,channels:4}}).png().toFile(path.join(out,'lut-fit-after.png'));await sharp(src.data,{raw:{...src.info,channels:4}}).png().toFile(path.join(out,'lut-fit-source.png'));}
 }
 checks.push('All bundled LUTs use bounded nonnegative brightness assistance, retain saturation and pass actual output tone safety');
 const a={...Film.spectralDefaults(),grain:0,bloom:0};
 for(const [i,name]of ['fixtures/01-valley.jpg','dng-fixtures/Apple-iPhone-12-Pro.DNG'].entries()){
   const input=path.join(__dirname,name);let referenceInput=input;
   if(/dng$/i.test(input)){const decoded=await h.request('decode_raw',{path:input}),m=decoded.result.image;referenceInput=path.join(out,'fit-dng-source.png');await sharp(decoded.payload,{raw:{width:m.width,height:m.height,channels:4}}).png().toFile(referenceInput);}
   const original=await sharp(referenceInput).resize(320,320,{fit:'inside'}).ensureAlpha().raw().toBuffer(),before=await h.render(input,a,320),fit=await job({kind:'auto-fit',input,referenceInput,adjustments:a}),adapted={...a,autoFitMode:'natural',autoFitEV:fit.ev,autoFitSaturation:fit.saturation},after=await h.render(input,adapted,320),s=Fit.measure(original),b=Fit.measure(before.data),c=Fit.measure(after.data);
   assert(fit.ev>=0&&fit.ev<=.75);assert.equal(fit.saturation,1);assert(c.p50>=b.p50-.002,name+' must not darken');assert(Fit.safeBrightness(b,c),name+' tone safety');
   const reference=await old.render(input,a,320);assert(Buffer.from(before.data).equals(Buffer.from(reference.data)),'Auto off must preserve 0.12 output');
   cases.push({engine:'spectral',input:name,ev:fit.ev,saturation:fit.saturation,sourceLuma:s.luminance,beforeLuma:b.luminance,afterLuma:c.luminance});
   if(i===0){await sharp(before.data,{raw:{width:before.width,height:before.height,channels:4}}).png().toFile(path.join(out,'spectral-fit-before.png'));await sharp(after.data,{raw:{width:after.width,height:after.height,channels:4}}).png().toFile(path.join(out,'spectral-fit-after.png'));}
   if(i===1){const dest=path.join(out,'auto-fit-dng-16.tif');await fs.rm(dest,{force:true});await h.exportImage(input,adapted,dest,'tiff',0);const meta=await sharp(dest).metadata();assert.equal(meta.width,3024);assert.equal(meta.height,4032);assert.equal(meta.bitsPerSample,16);assert(meta.icc.length>128);}
 }
 checks.push('Native brightness assistance retains metered brightness and tone separation; switching it off preserves v0.12 output exactly');checks.push('DNG brightness assistance exports at original dimensions with 16-bit samples and ICC');
 const clean=Film.cleanAdjustments({autoFitMode:'natural',autoFitVersion:2,autoFitEV:100,autoFitSaturation:-9,autoFitKey:'x'.repeat(900)});assert.equal(clean.autoFitEV,.75);assert.equal(clean.autoFitSaturation,1);assert.equal(clean.autoFitKey,'');
 await fs.writeFile(path.join(out,'auto-fit-native-report.json'),JSON.stringify({version,checks,cases},null,2));console.log(JSON.stringify({checks,cases},null,2));
}finally{await worker.terminate();await h.dispose();await old.dispose();}})().catch(e=>{console.error(e);process.exitCode=1;});


