// Product BW resources/defaults taken from the actual 1.3.3 bundle and public
// Params.swift. This is a Windows protocol/render check, not a Metal output.
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),sharp=require('sharp');
const {isDeepStrictEqual}=require('node:util');
const {SpectralHost}=require('../src/spectral-client.cjs'),{spectralDefaults,withSpectralFilm}=require('../src/film.cjs');
const version=require('../package.json').version,root=path.resolve(__dirname,'../../..'),out=process.env.DOSE_VERIFY_OUTPUT||path.join(root,'outputs/v'+version+'/verification');
const original=path.join(root,'work/dmg-audit/app-only/SpektraLab.app/Contents/Resources/Resources/engine');
const filmScales={kodak_tri_x_400:1.7,kodak_tmax_100:.74,fujifilm_neopan_acros_100_ii:.64,ilford_hp5_plus_400:1.49};
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const encode=v=>Math.round(255*(v<=.0031308?12.92*v:1.055*v**(1/2.4)-.055));
function neutrality(b){let max=0;for(let p=0;p<b.length;p+=4)max=Math.max(max,Math.abs(b[p]-b[p+1]),Math.abs(b[p+2]-b[p+1]));return max;}
function density(v){const x=v/255;return -Math.log10(Math.max(x<=.04045?x/12.92:((x+.055)/1.055)**2.4,1e-6));}
(async()=>{await fs.mkdir(out,{recursive:true});const h=new SpectralHost(),ref=new SpectralHost(),checks=[],films=[];
try{
  const catalog=h.catalog();assert.equal(catalog.films.length,24);assert.equal(catalog.papers.length,9);
  const releasedProfiles=(await fs.readdir(path.join(original,'profiles'))).filter(n=>n.endsWith('.json'));
  assert.equal(releasedProfiles.length,33);
  for(const name of releasedProfiles){const staged=await fs.readFile(path.join(h.home,'engine/profiles',name)),release=await fs.readFile(path.join(original,'profiles',name));assert(isDeepStrictEqual(JSON.parse(staged),JSON.parse(release)),name+' must match released bundle');if(filmScales[name.replace('.json','')]||name==='ilford_multigrade_iv_rc.json')assert.equal(hash(staged),hash(release),name+' product-profile bytes');}
  checks.push('All 33 staged profiles are semantically identical to the supplied 1.3.3 bundle; the five product profiles also match byte for byte');
  const patches=[[.184,.184,.184],[.45,.04,.03],[.08,.25,.06],[.15,.28,.55],[.03,.05,.35]],w=320,hg=64,pixels=Buffer.alloc(w*hg*3);
  for(let y=0;y<hg;y++)for(let x=0;x<w;x++)for(let k=0;k<3;k++)pixels[(y*w+x)*3+k]=encode(patches[Math.floor(x/64)][k]);
  const chart=path.join(out,'bw-colour-chart.png');await sharp(pixels,{raw:{width:w,height:hg,channels:3}}).withIccProfile('srgb').png().toFile(chart);
  const quiet={...spectralDefaults(),grain:0,bloom:0,halation:0,metering:'manual'},photo=path.join(__dirname,'fixtures/01-valley.jpg');
  const colourBefore=Buffer.from((await h.render(photo,quiet,800)).data);
  for(const [film,scale]of Object.entries(filmScales)){
    const settings=withSpectralFilm(quiet,film,catalog.films);assert.equal(settings.spectralPaper,'ilford_multigrade_iv_rc');
    const actual=await h.render(chart,settings,800),entry=await h.productSession(chart,settings,800);
    const p=entry.opened.params;assert.equal(p.y_filter_neutral,68);assert.equal(p.m_filter_neutral,0);assert.equal(p.c_filter_neutral,0);assert.equal(p.grain_sublayers_active,false);
    const expectedSession=(await ref.request('open',{path:chart,params:{product_defaults:true,preview_long_edge:800,film_stock:film,print_stock:'ilford_multigrade_iv_rc',film_format_mm:120,auto_exposure:false,scan_film:false,grain_active:false,grain_sublayers_active:false,halation_active:false,glare_active:false,c_filter_neutral:0,m_filter_neutral:0,y_filter_neutral:68,print_exposure:1,output_color_space:'ProPhoto RGB'}})).result.session;
    const expected=await ref.request('render',{session:expectedSession,tier:'live',reprint:true,format:'rgba8',display:'srgb'});assert(Buffer.from(actual.data).equals(expected.payload),film+' filter-2 reference');await ref.request('close',{session:expectedSession});
    const spread=neutrality(actual.data);assert(spread<=1,film+' silver print neutrality');
    let middle=0,n=0;for(let y=8;y<56;y++)for(let x=8;x<56;x++){middle+=actual.data[(y*w+x)*4+1];n++;}const midDensity=density(middle/n);assert(midDensity>.55&&midDensity<.95,film+' mid-grey '+midDensity);
    const grained=await h.productSession(photo,{...settings,grain:50},800);assert.equal(grained.delta.grain_amount,scale,film+' calibrated grain');const capped=await h.productSession(photo,{...settings,grain:100},800);assert.equal(capped.delta.grain_amount,Math.min(2,2*scale));
    const rendered=await h.render(photo,{...settings,grain:50},800);assert(neutrality(rendered.data)<=1,film+' photographic silver grain');await sharp(rendered.data,{raw:{width:rendered.width,height:rendered.height,channels:4}}).png().toFile(path.join(out,film+'.png'));
    films.push({id:film,resourceHash:hash(await fs.readFile(path.join(h.home,'engine/profiles',film+'.json'))),neutralFilter:[0,0,68],defaultGrain:scale,channelSpread8:spread,midDensity,independentParameterMaxDifference8:0});
  }
  checks.push('All four black-and-white films print neutrally with the original filter-2 pack and calibrated single-layer grain');
  const bw=withSpectralFilm(quiet,'kodak_tri_x_400',catalog.films);await assert.rejects(h.productSession(photo,{...bw,spectralPaper:'kodak_supra_endura'},800),/匹配/);
  await h.render(photo,bw,800);const back=await h.render(photo,quiet,800);assert(Buffer.from(back.data).equals(colourBefore),'BW to colour must restore original colour-neutral pack');checks.push('Incompatible paper is rejected; switching back from silver to colour restores the colour result exactly');
  const dng=path.join(__dirname,'dng-fixtures/Apple-iPhone-12-Pro.DNG'),sourceHash=hash(await fs.readFile(dng)),tiff=path.join(out,'bw-dng-16bit.tif');await fs.rm(tiff,{force:true});await h.exportImage(dng,{...bw,grain:50},tiff,'tiff',0);const meta=await sharp(tiff).metadata();assert.equal(meta.width,3024);assert.equal(meta.height,4032);assert.equal(meta.bitsPerSample,16);assert(meta.icc?.length>0);const raw=await sharp(tiff).toColourspace('rgb16').raw({depth:'ushort'}).toBuffer(),levels=new Set();for(let p=0;p<raw.length;p+=6*17)levels.add(raw.readUInt16LE(p));assert(levels.size>256);assert.equal(hash(await fs.readFile(dng)),sourceHash);const dngResult={width:meta.width,height:meta.height,bits:meta.bitsPerSample,sampledLevels:levels.size,icc:true,originalUnchanged:true};checks.push('Black-and-white DNG exports at original dimensions with 16-bit samples, more than 256 levels and an ICC profile; source file unchanged');
  await fs.writeFile(path.join(out,'black-and-white-report.json'),JSON.stringify({version,checks,films,dng:dngResult,scope:'Real Windows Vulkan renders and original-bundle resource equality; no macOS golden image supplied'},null,2));console.log(JSON.stringify({checks,films,dng:dngResult},null,2));
}finally{await h.dispose();await ref.dispose();}})().catch(e=>{console.error(e);process.exitCode=1;});
