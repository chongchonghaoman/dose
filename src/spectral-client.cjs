const {spawn}=require('node:child_process');
const path=require('node:path'),fs=require('node:fs'),os=require('node:os'),crypto=require('node:crypto'),sharp=require('sharp');
function homeDir(){
  if(process.env.DOSE_SPECTRAL_HOME)return process.env.DOSE_SPECTRAL_HOME;
  const packaged=process.resourcesPath&&path.join(process.resourcesPath,'spectral');
  return packaged&&fs.existsSync(path.join(packaged,'spektralab-host.exe'))?packaged:path.join(__dirname,'..','native','spectral');
}
// Matches FilmParams.wire + Session.openDelta in SpektraLab 99c2d5c.
// `film_format_mm` is the physical long edge, not the 135-format name.
// FilmParams.ownGrain: the product calibrates these silver emulsions separately.
const SILVER_GRAIN=Object.freeze({kodak_tri_x_400:1.70,ilford_hp5_plus_400:1.49,kodak_tmax_100:.74,fujifilm_neopan_acros_100_ii:.64});
function productDelta(a,width,height,size=2560,film={},paper={}){
  const aspect=Math.max(width,height)/Math.max(1,Math.min(width,height));
  const natural=a.spectralIntent==='natural';
  return {product_defaults:true,preview_long_edge:Math.min(8192,Math.max(800,size)),
    film_stock:a.spectralFilm,print_stock:a.spectralPaper,
    film_format_mm:Math.min(200,(a.filmFormat===60?56:24)*aspect),
    auto_exposure:!natural&&a.metering!=='manual',auto_exposure_method:a.metering==='manual'?'balanced':a.metering,
    exposure_compensation_ev:a.exposure,print_exposure:2**(-a.printExposure),
    grain_active:a.grain>0,grain_sublayers_active:!film.monochrome,grain_amount:Math.min(2,a.grain/50*(SILVER_GRAIN[a.spectralFilm]||1)),
    halation_active:a.halation>0,halation_amount:a.halation/25,halation_scatter_amount:1,
    antihalation_removed:false,halation_boost_ev:0,
    dir_couplers_active:true,dir_couplers_amount:1,
    glare_active:a.bloom>0,glare_amount:a.bloom*.3,
    y_filter_shift:0,m_filter_shift:0,filter_shift_scale:1,scan_film:film.type==='positive',
    extended_dynamic_range:false,preflash_exposure:0,
    contrast_mask_active:a.spectralMask===true,contrast_mask_highlights:a.spectralMaskHighlights||0,contrast_mask_shadows:a.spectralMaskShadows||0,
    contrast_mask_core:1,contrast_mask_scale:.03,contrast_mask_scheme:'gaussian',
    overscan_active:a.spectralEdge===true,
    overscan_format:a.filmFormat===60?(aspect<1.12?'120_6x6':aspect<1.29?'120_6x7':aspect<1.43?'120_645':'120_6x9'):'135',
    overscan_mode:'strip',overscan_pair:false,overscan_carrier:'none',
    date_imprint_active:a.spectralDate===true&&!!a.spectralDateText,
    date_imprint_text:a.spectralDateText||'',date_imprint_placement:'frame',
    date_imprint_style:'lcd',date_imprint_corner:'br',
    // Already rendered photos must not be remetered to middle grey. Place
    // their extremes before film density and paper contrast, while still float.
    scene_latitude_active:natural,scene_latitude_norm:natural?'y':'power',scene_latitude_highlight_knee:natural?1:2,
    scene_latitude_highlight_room:natural?2**(a.highlights/50):0,scene_latitude_shadow_knee:natural?0:-2,scene_latitude_shadow_room:natural?1.5*2**(-a.shadows/50):0,
    scene_latitude_rolloff:2,scene_latitude_max_lift:4,
    scanner_unsharp_radius:.7,scanner_unsharp_amount:natural?0:.7,
    digital_intermediate:false,digital_intermediate_blue_compensation:false,
    // The base engine table has no silver-paper row. The original app sends
    // Multigrade filter 2 explicitly; without it the print is too contrasty.
    ...(film.monochrome&&paper.monochrome?{c_filter_neutral:0,m_filter_neutral:0,y_filter_neutral:68}:{}),
    output_color_space:'ProPhoto RGB',output_cctf_encoding:true};
}
function layer2Grade(a){return {temperature:a.temperature/100,contrast:a.contrast/100,
  saturation:a.saturation/100,highlights:a.spectralIntent==='natural'?0:a.highlights/100,shadows:a.spectralIntent==='natural'?0:a.shadows/100,
  auto_fit_active:a.autoFitMode==='natural'&&a.autoFitVersion===2,auto_fit_ev:a.autoFitVersion===2&&Number.isFinite(a.autoFitEV)?Math.min(.75,Math.max(0,a.autoFitEV)):0,auto_fit_saturation:1};}
class SpectralHost {
  constructor(opts={}){this.home=opts.home||homeDir();this.child=null;this.buf=Buffer.alloc(0);this.next=1;this.pending=new Map();this.sessions=new Map();this.stderr='';this.temp=null;}
  start(){
    if(this.child)return;
    const exe=path.join(this.home,'spektralab-host.exe');
    if(!fs.existsSync(exe))throw Error('未找到 Windows 光谱引擎，请使用完整的 dose 安装目录');
    this.buf=Buffer.alloc(0);this.stderr='';
    const child=this.child=spawn(exe,['--resources',path.join(this.home,'engine'),'--log-level','error'],{stdio:['pipe','pipe','pipe'],windowsHide:true});
    child.stdout.on('data',d=>this._data(d));child.stderr.on('data',d=>{this.stderr=(this.stderr+d.toString()).slice(-4000);});
    child.stdin.on('error',e=>{if(this.child===child)this._fail(e);});child.on('error',e=>{if(this.child===child)this._fail(e);});
    child.on('exit',(c,s)=>{if(this.child===child)this._fail(Error(`光谱引擎退出 (${c??s}) ${this.stderr}`));});
  }
  _fail(error){const child=this.child;this.child=null;child?.kill();for(const p of this.pending.values())p.reject(error);this.pending.clear();this.sessions.clear();this.buf=Buffer.alloc(0);}
  _data(d){
    this.buf=Buffer.concat([this.buf,d]);
    while(this.buf.length>=8){
      const h=this.buf.readUInt32LE(0),n=this.buf.readUInt32LE(4);
      if(h>16*1024*1024||n>600*1024*1024)return this._fail(Error('光谱引擎返回异常数据长度'));
      if(this.buf.length<8+h+n)return;
      let msg;try{msg=JSON.parse(this.buf.subarray(8,8+h).toString('utf8'));}catch{return this._fail(Error('光谱引擎协议错误'));}
      const payload=this.buf.subarray(8+h,8+h+n);this.buf=this.buf.subarray(8+h+n);
      if(msg.id==null)continue;const p=this.pending.get(msg.id);if(!p)continue;this.pending.delete(msg.id);
      if(!msg.ok)p.reject(Error(msg.error?.message||'光谱渲染失败'));else p.resolve({result:msg.result||{},payload});
    }
  }
  request(method,params={}){
    this.start();const id=this.next++,body=Buffer.from(JSON.stringify({id,method,params})),frame=Buffer.alloc(8+body.length);frame.writeUInt32LE(body.length,0);body.copy(frame,8);
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>this._fail(Error(`光谱引擎 ${method} 超时`)),120000);this.pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});this.child.stdin.write(frame);});
  }
  catalog(){
    if(this.stocks)return this.stocks;
    const dir=path.join(this.home,'engine','profiles'),films=[],papers=[];
    for(const name of fs.readdirSync(dir).filter(n=>n.endsWith('.json'))){const {info}=JSON.parse(fs.readFileSync(path.join(dir,name),'utf8'));if(!info?.stock)continue;const item={id:info.stock,name:info.name||info.stock,type:info.type,targetPrint:info.target_print||null,monochrome:info.channel_model==='bw'};if(info.stage==='filming')films.push(item);if(info.stage==='printing')papers.push(item);}
    return this.stocks={films,papers};
  }
  async status(){const {result}=await this.request('hello');if(!result.backend?.available)throw Error(result.backend?.error||'显卡 Vulkan 光谱引擎不可用');return {available:true,backend:result.backend,...this.catalog()};}
  async renderManaged(input,a,size=1600){
    if(a.spectralVersion!==2)return this.render(input,a,size);
    const entry=await this.productSession(input,a,size);
    const out=await this.request('render',{session:entry.session,tier:'live',reprint:true,format:'png16',grade:layer2Grade(a)});
    const {width,height}=out.result.image;
    if(out.payload.length<33||out.payload.toString('ascii',1,4)!=='PNG'||out.payload[24]!==16)throw Error('光谱预览编码无效');
    // Do not run a second gamut/lightness transform or an 8-bit Sharp resize.
    // A tagged 16-bit working image reaches the browser's colour manager.
    return {width,height,encoding:'png',colorSpace:'ProPhoto RGB',bits:16,data:new Uint8Array(out.payload),timings:out.result.timings_ms};
  }
  async render(input,a,size){
    if(a.spectralVersion===2){
      const entry=await this.productSession(input,a,size);
      const out=await this.request('render',{session:entry.session,tier:'live',reprint:true,format:'rgba8',display:'srgb',grade:layer2Grade(a)});
      let {width,height}=out.result.image;
      if(out.payload.length!==width*height*4)throw Error('光谱图像尺寸不匹配');
      let data=out.payload;
      if(Math.max(width,height)>size){const resized=await sharp(data,{raw:{width,height,channels:4}}).resize(size,size,{fit:'inside'}).raw().toBuffer({resolveWithObject:true});data=resized.data;width=resized.info.width;height=resized.info.height;}
      return {width,height,data:new Uint8Array(data),timings:out.result.timings_ms};
    }
    const catalog=this.catalog();if(!catalog.films.some(x=>x.id===a.spectralFilm)||!catalog.papers.some(x=>x.id===a.spectralPaper))throw Error('胶片或相纸配置不存在');
    const stat=await fs.promises.stat(input),key=crypto.createHash('sha256').update(`${input}:${stat.mtimeMs}:${stat.size}:${size}`).digest('hex');
    const delta={film_stock:a.spectralFilm,print_stock:a.spectralPaper,film_format_mm:a.filmFormat,auto_exposure:false,exposure_compensation_ev:a.exposure,print_exposure:2**a.printExposure,grain_active:a.grain>0,grain_amount:a.grain/50,halation_active:a.halation>0,halation_amount:a.halation/25,glare_active:a.bloom>0,glare_amount:a.bloom*.3,output_color_space:'sRGB',output_cctf_encoding:true};
    let session=this.sessions.get(key);
    if(session){this.sessions.delete(key);this.sessions.set(key,session);await this.request('set_params',{session,delta});}
    else{
      if(!this.temp)this.temp=await fs.promises.mkdtemp(path.join(os.tmpdir(),'dose-spectral-'));
      const prepared=path.join(this.temp,key+'.png');
      await sharp(input,{limitInputPixels:150000000,failOn:'error'}).rotate().resize(size,size,{fit:'inside',withoutEnlargement:true}).flatten({background:'#ffffff'}).toColourspace('srgb').png().toFile(prepared);
      try{session=(await this.request('open',{path:prepared,params:delta})).result.session;}finally{await fs.promises.unlink(prepared).catch(()=>{});}
      this.sessions.set(key,session);
      while(this.sessions.size>3){const [oldKey,oldSession]=this.sessions.entries().next().value;await this.request('close',{session:typeof oldSession==='string'?oldSession:oldSession.session});this.sessions.delete(oldKey);}
    }
    // Retain the v0.9 adapter exclusively for already-saved version 1 recipes.
    const out=await this.request('render',{session,tier:'full',reprint:true,format:'rgba8',display:'srgb'}),{width,height}=out.result.image;
    if(out.payload.length!==width*height*4)throw Error('光谱图像尺寸不匹配');
    if(size>1600){await this.request('close',{session});this.sessions.delete(key);}
    return {width,height,data:new Uint8Array(out.payload),timings:out.result.timings_ms};
  }
  async productSession(input,a,size=2560){
    const catalog=this.catalog();if(!catalog.films.some(x=>x.id===a.spectralFilm)||!catalog.papers.some(x=>x.id===a.spectralPaper))throw Error('胶片或相纸配置不存在');
    const film=catalog.films.find(x=>x.id===a.spectralFilm);
    const paper=catalog.papers.find(x=>x.id===a.spectralPaper);
    if(film.type!=='positive'&&film.monochrome!==paper.monochrome)throw Error('请选择与胶片匹配的相纸');
    const stat=await fs.promises.stat(input),key=`v2:${input}:${stat.mtimeMs}:${stat.size}`;
    let entry=this.sessions.get(key);
    if(entry){this.sessions.delete(key);this.sessions.set(key,entry);}
    else{
      // Bound full-resolution RAW allocations before opening another image.
      while(this.sessions.size>=2){const [k,v]=this.sessions.entries().next().value;await this.request('close',{session:typeof v==='string'?v:v.session});this.sessions.delete(k);}
      let source=input,prepared;
      // The upstream host reads JPEG/PNG/TIFF/RAW. Keep the other previously
      // supported raster formats by decoding once at native size into RGB16.
      // RAW never enters this conversion branch.
      if(/\.(webp|avif|gif)$/i.test(input)){
        if(!this.temp)this.temp=await fs.promises.mkdtemp(path.join(os.tmpdir(),'dose-spectral-'));
        source=prepared=path.join(this.temp,crypto.createHash('sha256').update(key).digest('hex')+'.png');
        await sharp(input,{limitInputPixels:150000000,failOn:'error'}).pipelineColourspace('rgb16').rotate().flatten({background:'#ffffff'}).toColourspace('rgb16').png().toFile(prepared);
      }
      let opened;
      try{const meta=(await this.request('probe',{path:source})).result;
        opened=(await this.request('open',{path:source,params:productDelta(a,meta.width,meta.height,size,film,paper)})).result;
      }finally{if(prepared)await fs.promises.unlink(prepared).catch(()=>{});}
      entry={session:opened.session,width:opened.width,height:opened.height,opened,input,
        delta:productDelta(a,(opened.width||1),(opened.height||1),size,film,paper)};
      // Opening can use sensor probe dimensions that differ from the cropped
      // decoded frame. Send that physical-format correction once when needed.
      entry.delta.film_format_mm=opened.params.film_format_mm;delete entry.delta.product_defaults;
      this.sessions.set(key,entry);
    }
    // Decode orientation does not change the long/short aspect ratio. Use the
    // actual decoded dimensions (LibRaw can trim masked sensor borders).
    const delta=productDelta(a,entry.width,entry.height,size,film,paper);delete delta.product_defaults;
    const changed=Object.fromEntries(Object.entries(delta).filter(([key,value])=>entry.delta[key]!==value));
    if(Object.keys(changed).length){await this.request('set_params',{session:entry.session,delta:changed});entry.delta=delta;}
    return entry;
  }
  async exportImage(input,a,output,format='jpeg',size=6000,quality=96){
    if(a.spectralVersion!==2)throw Error('高精度导出需要新版光谱配方');
    const entry=await this.productSession(input,a,2560);
    try{return (await this.request('export_image',{session:entry.session,path:output,
      format:format==='tiff'?'tiff16':format,color_space:format==='tiff'?'prophoto':'srgb',
      long_edge:size,quality,grade:layer2Grade(a),overwrite:false})).result;}
    finally{await this.request('close',{session:entry.session});for(const [key,value] of this.sessions)if(value===entry)this.sessions.delete(key);}
  }
  async dispose(){if(this.child){try{await this.request('shutdown');}catch{}this.child?.kill();this.child=null;}if(this.temp)await fs.promises.rm(this.temp,{recursive:true,force:true});}
}
module.exports={SpectralHost,homeDir,productDelta,layer2Grade};
