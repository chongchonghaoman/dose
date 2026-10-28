// Same-file comparison against the pre-change native Windows host, using
// independently transcribed upstream product parameters (not productDelta()).
// This verifies the adapter; it does not claim Metal/Vulkan platform parity.
const assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto'),sharp=require('sharp');
const {SpectralHost,layer2Grade}=require('../src/spectral-client.cjs');
const {spectralDefaults,cleanAdjustments}=require('../src/film.cjs');
const version=require('../package.json').version,root=path.resolve(__dirname,'../../..'),out=process.env.DOSE_VERIFY_OUTPUT||path.join(root,'outputs/v'+version+'/verification');
const referenceHome=process.env.DOSE_REFERENCE_HOME||path.join(root,'outputs/v0.9.1/dose-win32-x64/resources/spectral');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const mean=b=>{let y=0;for(let i=0;i<b.length;i+=4)y+=.2126*b[i]+.7152*b[i+1]+.0722*b[i+2];return y/(b.length/4)};
function diff(a,b,depth=8){assert.equal(a.length,b.length);let max=0,sum=0,count=0;for(let i=0;i<a.length;i+=depth/8){if((i/(depth/8))%4===3)continue;const d=Math.abs(depth===16?a.readUInt16LE(i)-b.readUInt16LE(i):a[i]-b[i]);max=Math.max(max,d);sum+=d;count++;}return {max,mean:sum/count};}
function referenceParams(w,h,delta={}){return {
  product_defaults:true,preview_long_edge:800,film_stock:'kodak_portra_400',print_stock:'kodak_supra_endura',
  auto_exposure:true,auto_exposure_method:'balanced',exposure_compensation_ev:0,
  film_format_mm:24*Math.max(w,h)/Math.min(w,h),grain_active:true,grain_sublayers_active:true,
  halation_active:true,print_exposure:1,y_filter_shift:0,m_filter_shift:0,filter_shift_scale:1,
  glare_active:true,scan_film:false,extended_dynamic_range:false,preflash_exposure:0,
  contrast_mask_active:false,contrast_mask_highlights:0,contrast_mask_shadows:0,contrast_mask_core:1,
  contrast_mask_scale:.03,contrast_mask_scheme:'gaussian',scene_latitude_active:false,scene_latitude_norm:'power',
  scene_latitude_highlight_knee:2,scene_latitude_highlight_room:0,scene_latitude_shadow_knee:-2,
  scene_latitude_shadow_room:0,scene_latitude_rolloff:2,scene_latitude_max_lift:4,
  halation_amount:1,halation_scatter_amount:1,grain_amount:1,dir_couplers_active:true,dir_couplers_amount:1,
  glare_amount:1,antihalation_removed:false,halation_boost_ev:0,digital_intermediate:false,
  digital_intermediate_blue_compensation:false,...delta};}
// Independent translation of Shaders.metal:136-142,270-312,403.
function gradeOracle(input,g){const output=Buffer.from(input),mid=.3857,clamp=x=>Math.min(1,Math.max(0,x));
  for(let i=0;i<input.length;i+=8){let c=[0,1,2].map(k=>input.readUInt16LE(i+k*2)/65535);
    c=c.map((v,k)=>v*[1+.18*(g.temperature||0),1-.12*(g.tint||0),1-.18*(g.temperature||0)][k]);
    if(g.exposure)c=c.map(v=>(Math.max(v,0)**2.2*2**g.exposure)**(1/2.2));
    if(g.contrast)c=c.map(v=>(v-mid)*(1+g.contrast*1.2)+mid);
    if(g.brightness)c=c.map(v=>Math.max(v,0)**(1/(1+g.brightness*.8)));
    let l=.2126*c[0]+.7152*c[1]+.0722*c[2],position=l<=mid?.5*l/mid:.5+.5*(l-mid)/(1-mid);
    if(g.shadows)c=c.map(v=>v+g.shadows*.25*(1-position)**2*(1-v));
    if(g.highlights)c=c.map(v=>v+g.highlights*.25*position**2*(g.highlights>0?1-v:v));
    c=c.map(v=>(v-(g.black_point||0))/Math.max(1-(g.black_point||0)-(g.white_point||0),.05));
    l=.2126*c[0]+.7152*c[1]+.0722*c[2];c=c.map(v=>l+(v-l)*(1+(g.saturation||0)));
    c.forEach((v,k)=>output.writeUInt16LE(Math.round(clamp(v)*65535),i+k*2));
  }return output;
}
function tiffPrecision(b){assert.equal(b.toString('ascii',0,2),'II');const ifd=b.readUInt32LE(4),n=b.readUInt16LE(ifd),tags=new Map();for(let i=0;i<n;i++){const p=ifd+2+i*12,tag=b.readUInt16LE(p),type=b.readUInt16LE(p+2),count=b.readUInt32LE(p+4),bytes=type===3?2:4,off=count*bytes>4?b.readUInt32LE(p+8):p+8;tags.set(tag,Array.from({length:count},(_,j)=>bytes===2?b.readUInt16LE(off+j*2):b.readUInt32LE(off+j*4)));}
  assert.deepEqual(tags.get(258),[16,16,16]);assert.equal(tags.get(259)[0],1);assert(tags.has(34675),'ICC missing');
  const values=[new Set(),new Set(),new Set()];let non8=0,count=0;for(let s=0;s<tags.get(273).length;s++){const start=tags.get(273)[s],end=start+tags.get(279)[s];for(let p=start;p<end;p+=2){const v=b.readUInt16LE(p);values[count%3].add(v);non8+=v%257!==0;count++;}}
  const result={width:tags.get(256)[0],height:tags.get(257)[0],bits:16,uniqueLevels:values.map(v=>v.size),non8BitGridFraction:non8/count,icc:true};assert(result.uniqueLevels.every(n=>n>256));assert(result.non8BitGridFraction>.8);return result;
}
(async()=>{await fs.mkdir(out,{recursive:true});const host=new SpectralHost(),ref=new SpectralHost({home:referenceHome}),checks=[],comparisons=[],tiles=[];
try{
  const status=await host.status();assert.equal(status.backend.render_core,'native-vulkan');
  const legacy=cleanAdjustments({engine:'spectral',spectralPaper:'kodak_portra_endura',exposure:1,grain:7});assert.equal(legacy.spectralVersion,1);assert.equal(legacy.grain,7);assert.equal(legacy.spectralPaper,'kodak_portra_endura');checks.push('Unversioned saved recipes stay on version 1');
  const a=spectralDefaults();assert.equal(a.bloom*.3,1);assert.equal(cleanAdjustments({...a,exposure:7.2}).exposure,7.2);
  const files=['fixtures/01-valley.jpg','fixtures/06-castle.jpg','dng-fixtures/Apple-iPhone-12-Pro.DNG','dng-fixtures/Ricoh-GR-III.DNG'];
  for(let index=0;index<files.length;index++){
    const file=path.join(__dirname,files[index]),before=hash(await fs.readFile(file));
    const start=Date.now(),entry=await host.productSession(file,a,800);
    assert(entry);assert.equal(entry.opened.output_color_space,'ProPhoto RGB');assert.equal(entry.opened.detected_input.input_cctf_decoding,false);
    const opened=(await ref.request('open',{path:file,params:referenceParams(entry.width,entry.height)})).result;
    // Pin the physical result before the former host's repeated lightness
    // shoulder. Separate independent CPU tests verify the corrected export.
    const expected=await ref.request('render',{session:opened.session,tier:'live',reprint:true,format:'rgba16'});
    const working=await host.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba16'});
    const difference=diff(working.payload,expected.payload,16);assert(difference.max<=1,`Working-space mismatch ${files[index]} ${JSON.stringify(difference)}`);
    const actual=await host.render(file,a,800);
    const png=path.join(out,`case-${index+1}-dose.png`);await sharp(actual.data,{raw:{width:actual.width,height:actual.height,channels:4}}).png().toFile(png);
    await fs.writeFile(path.join(out,`case-${index+1}-reference.rgba16`),expected.payload);
    comparisons.push({input:files[index],sourceSha256:before,width:entry.width,height:entry.height,preview:[actual.width,actual.height],workingDifference16:difference,ms:Date.now()-start,reference:'pre-change Windows native host; original product parameters; before display conversion',originalUnchanged:before===hash(await fs.readFile(file))});
    tiles.push({index,png,width:actual.width,height:actual.height});
    await ref.request('close',{session:opened.session});
    if(index>=2){const target=path.join(out,`case-${index+1}-16bit.tif`);await fs.rm(target,{force:true});await host.exportImage(file,{...a,highlights:-25,shadows:15},target,'tiff',0,96);comparisons.at(-1).tiff=tiffPrecision(await fs.readFile(target));assert.equal(comparisons.at(-1).tiff.width,entry.width);assert.equal(comparisons.at(-1).tiff.height,entry.height);}
    console.log('same-image',files[index],JSON.stringify(difference));
  }
  checks.push('Four same-source working RGBA16 outputs match original-parameter Windows reference (including grain/halation/glare), before corrected display conversion');
  checks.push('Both Bayer DNG and Apple ProRAW enter directly as linear ProPhoto, export full-size 16-bit ProPhoto TIFF with ICC');
  const file=path.join(__dirname,files[0]),det={...a,grain:0,bloom:0};
  const base=await host.render(file,det,800),ev=await host.render(file,{...det,exposure:1},800),print=await host.render(file,{...det,printExposure:1},800);
  const luma={base:mean(base.data),cameraPlusOne:mean(ev.data),printPlusOne:mean(print.data)};assert(luma.cameraPlusOne>luma.base+5);assert(luma.printPlusOne>luma.base+5);checks.push('Camera exposure +1 and print brightness +1 both increase actual brightness');
  // Grade against raw ProPhoto samples; deterministic negative, no display or
  // color-management implementation shared with the expected-value function.
  const entry=await host.productSession(file,det,800),raw=(await host.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba16'})).payload;
  const grades=[{shadows:.8},{highlights:-.8},{temperature:.7},{contrast:.6},{contrast:-.6,saturation:-.6},{temperature:-.8,tint:.3,exposure:.4,contrast:.2,brightness:.15,shadows:.4,highlights:-.5,black_point:.03,white_point:.02,saturation:.3}];
  const gradeChecks=[];for(const grade of grades){const actual=(await host.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba16',grade})).payload;const d=diff(actual,gradeOracle(raw,grade),16);assert(d.max<=2,`Layer2 mismatch ${JSON.stringify(grade)} ${JSON.stringify(d)}`);gradeChecks.push({grade,difference16:d});}
  checks.push('Six independent Layer2 formula tests match within 2/65535 (including dark/mid/high tones and combined controls)');
  // Lossless preview/export equality at the same size uses a real 800px source,
  // so the test is not confounded by different-resolution physical grain.
  const small=path.join(out,'same-size-input.png');await sharp(file).resize(800).png().toFile(small);
  const graded={...det,highlights:-30,shadows:20,contrast:8,temperature:12,saturation:-7};
  const preview=await host.render(small,graded,800),exportPath=path.join(out,'same-size-export.png');await fs.rm(exportPath,{force:true});await host.exportImage(small,graded,exportPath,'png',800);
  const exported=await sharp(exportPath).ensureAlpha().raw().toBuffer();const exportDifference=diff(Buffer.from(preview.data),exported);assert(exportDifference.max<=1);checks.push('High-precision graded PNG export matches same-size sRGB soft proof within 1/255; canvas uses its ICC-managed working-space path');
  const report={version,upstreamCommit:'99c2d5c9883be485085895157279cc7c4eaa8db6',referenceHostSha256:hash(await fs.readFile(path.join(referenceHome,'spektralab-host.exe'))),hostSha256:hash(await fs.readFile(path.join(host.home,'spektralab-host.exe'))),status,checks,comparisons,luma,gradeChecks,exportDifference,limits:['No macOS/Metal output was available; this is Windows native adapter and formula verification, not a cross-platform pixel-parity claim.','LibRaw compatible 16-bit decode; no claim of unlimited sensor highlight headroom.','HEIC remains the existing SDR decoder.']};
  await fs.writeFile(path.join(out,'fidelity-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({checks,luma,gradeChecks,exportDifference},null,2));
}finally{await host.dispose();await ref.dispose();}})().catch(e=>{console.error(e);process.exitCode=1});

