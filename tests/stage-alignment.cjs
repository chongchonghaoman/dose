const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp');
const {SpectralHost}=require('../src/spectral-client.cjs'),{spectralDefaults,withSpectralFilm}=require('../src/film.cjs');
const version=require('../package.json').version,out=process.env.DOSE_VERIFY_OUTPUT||path.resolve(__dirname,'../../../outputs/v'+version+'/verification'),input=path.join(__dirname,'fixtures/01-valley.jpg');
(async()=>{await fs.mkdir(out,{recursive:true});const h=new SpectralHost(),ref=new SpectralHost(),checks=[],positive=[];
try{const a={...spectralDefaults(),grain:0,bloom:0},catalog=h.catalog();
for(const film of catalog.films.filter(f=>f.type==='positive')){
  const settings={...a,spectralFilm:film.id},actual=await h.render(input,settings,800),entry=await h.productSession(input,settings,800);
  const expectedSession=(await ref.request('open',{path:input,params:{product_defaults:true,preview_long_edge:800,film_stock:film.id,print_stock:'kodak_supra_endura',film_format_mm:36,auto_exposure:true,auto_exposure_method:'balanced',scan_film:true,grain_active:false,glare_active:false,output_color_space:'ProPhoto RGB'}})).result.session;
  const expected=await ref.request('render',{session:expectedSession,tier:'live',reprint:true,format:'rgba8',display:'srgb'});assert(Buffer.from(actual.data).equals(expected.payload),film.id+' original direct-scan branch');
  await h.request('set_params',{session:entry.session,delta:{scan_film:false}});const wrong=await h.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba8',display:'srgb'});let delta=0;for(let k=0;k<wrong.payload.length;k++)delta+=Math.abs(wrong.payload[k]-actual.data[k]);assert(delta/wrong.payload.length>1,film.id+' should differ from erroneous paper processing');
  positive.push({film:film.id,scanReferenceMaxDifference:0,oldPrintBranchMeanDifference:delta/wrong.payload.length});
  // Direct protocol mutation above bypasses the adapter's delta bookkeeping;
  // restore it before asking that same adapter to switch the next stock.
  await h.request('set_params',{session:entry.session,delta:{scan_film:true}});
  if(film.id==='fujifilm_provia_100f'){await sharp(actual.data,{raw:{width:actual.width,height:actual.height,channels:4}}).png().toFile(path.join(out,'provia-scan.png'));await sharp(wrong.payload,{raw:{width:actual.width,height:actual.height,channels:4}}).png().toFile(path.join(out,'provia-old-print.png'));}
  await ref.request('close',{session:expectedSession});
}
checks.push('Four reversal films use direct scan and match independently requested upstream scan branch');
const cine=withSpectralFilm(a,'kodak_vision3_250d',catalog.films);assert.equal(cine.spectralPaper,'kodak_2383');assert.equal(withSpectralFilm({...a,spectralVersion:1},'kodak_vision3_250d',catalog.films).spectralPaper,a.spectralPaper);checks.push('Choosing cinema negative follows its declared print; legacy recipes retain their own pair');
await h.render(input,a,800);const entry=await h.productSession(input,{...a,printExposure:.5},800);const printed=await h.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba8',display:'srgb'});assert(printed.result.negative_was_cached);checks.push('Print exposure change reuses cached negative');
await fs.writeFile(path.join(out,'stage-alignment.json'),JSON.stringify({version,checks,positive,reprint:{tier:printed.result.tier,reprinted:printed.result.reprinted,negative_was_cached:printed.result.negative_was_cached},scope:'Windows branch/adapter validation, not macOS golden-output parity'},null,2));console.log(JSON.stringify({checks,positive},null,2));
}finally{await h.dispose();await ref.dispose();}})().catch(e=>{console.error(e);process.exitCode=1});
