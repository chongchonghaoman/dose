const assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path'),sharp=require('sharp');
const {SpectralHost}=require('../src/spectral-client.cjs');
const {cleanAdjustments,naturalDefaults}=require('../src/film.cjs');
const out=path.resolve(process.env.DOSE_COMMUNITY_OUTPUT||path.join(__dirname,'results/community-native'));
(async()=>{
 await fs.mkdir(out,{recursive:true});const host=new SpectralHost(),checks=[];
 const input=path.join(__dirname,'fixtures/01-valley.jpg'),a=cleanAdjustments({...naturalDefaults(),grain:0,halation:0,bloom:0});
 const save=async(name,r)=>sharp(r.data,{raw:{width:r.width,height:r.height,channels:4}}).png().toFile(path.join(out,name+'.png'));
 try{
  const status=await host.status();assert(status.available);
  const base=await host.render(input,a,800);await save('original-pipeline',base);
  const edge=await host.render(input,{...a,spectralEdge:true},800);assert(edge.height>base.height);await save('film-edge',edge);
  const dated=await host.render(input,{...a,spectralEdge:true,spectralDate:true,spectralDateText:'2026-10-29'},800);assert.equal(dated.width,edge.width);assert.equal(dated.height,edge.height);assert.notDeepEqual(dated.data,edge.data);await save('film-edge-date',dated);
  const date2=await host.render(input,{...a,spectralEdge:true,spectralDate:true,spectralDateText:'2025-06-12'},800);assert.notDeepEqual(date2.data,dated.data);checks.push('Native film edge expands output; explicit dates change pixels');
  const mask=await host.render(input,{...a,spectralMask:true,spectralMaskHighlights:1,spectralMaskShadows:.6},800);assert.equal(mask.width,base.width);assert.notDeepEqual(mask.data,base.data);await save('contrast-mask',mask);
  const restored=await host.render(input,a,800);assert.deepEqual(restored.data,base.data);checks.push('Mask changes pixels; disabling all finishing restores exact baseline');
  const medium=await host.render(input,{...a,filmFormat:60,spectralEdge:true},800);await save('medium-format-edge',medium);assert(medium.data.length===medium.width*medium.height*4);
  const managed=await host.renderManaged(input,{...a,spectralEdge:true},800);const meta=await sharp(managed.data).metadata();assert.equal(meta.bitsPerSample,16);assert(meta.icc?.length>0);checks.push('Managed preview retains 16-bit tagged colour with native edge');
  for(const format of ['jpeg','png','tiff']){
    const file=path.join(out,'export.'+format);await fs.rm(file,{force:true});
    await host.exportImage(input,{...a,spectralEdge:true,spectralDate:true,spectralDateText:'2026-10-29'},file,format,800);
    const m=await sharp(file).metadata();assert(m.width&&m.height);assert(m.icc?.length>0);if(format==='tiff')assert.equal(m.bitsPerSample,16);
  }
  checks.push('JPEG / PNG / TIFF export with edge + date and embedded ICC; TIFF remains 16-bit');
  if(process.env.DOSE_RAW_FIXTURE){const raw=await host.render(process.env.DOSE_RAW_FIXTURE,{...a,spectralEdge:true,spectralDate:true,spectralDateText:'2026-10-29'},800);await save('raw-film-edge-date',raw);checks.push('Real RAW processed through native edge/date');}
  await fs.writeFile(path.join(out,'report.json'),JSON.stringify({passed:true,backend:status.backend,checks},null,2));console.log(checks.join('\n'));
 }finally{await host.dispose();}
})().catch(e=>{console.error(e);process.exitCode=1;});
