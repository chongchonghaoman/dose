const {parentPort}=require('node:worker_threads');
const fs=require('node:fs/promises');
const sharp=require('sharp');
const {parseCube,applyPixels,applyTexture,cleanAdjustments}=require('./film.cjs');
const {SpectralHost}=require('./spectral-client.cjs');
const AutoFit=require('./auto-fit.js');
sharp.concurrency(2);sharp.cache({memory:48,files:4,items:10});
const cubes=new Map();let queue=Promise.resolve();
let spectral=null;
parentPort.on('message', job=>{
  queue=queue.catch(()=>{}).then(async()=>{
    try{
      if(job.kind==='decode-heic'){await require('./heic.cjs').decodeHeic(job.input,job.output);parentPort.postMessage({id:job.id,ok:true});return;}
      if(job.kind==='decode-dng'){
        spectral ||= new SpectralHost();const decoded=await spectral.request('decode_raw',{path:job.input});
        const {width,height}=decoded.result.image||{};
        if(!width||!height||width*height>150000000||decoded.payload.length!==width*height*4)throw Error('DNG 图像尺寸无效');
        await sharp(decoded.payload,{raw:{width,height,channels:4}}).png().toFile(job.output);
        parentPort.postMessage({id:job.id,ok:true});return;
      }
      if(job.kind==='spectral-status'){
        spectral ||= new SpectralHost();
        const result=await spectral.status(); parentPort.postMessage({id:job.id,ok:true,result}); return;
      }
      if(job.kind==='spectral-preview'){
        spectral ||= new SpectralHost();
        const a=cleanAdjustments(job.adjustments),result=await spectral.renderManaged(job.input,a,job.size||400);
        if(a.spectralVersion!==2)applyPixels(result.data,4,{...a,engine:'lut',lut:false,exposure:0,grain:0,halation:0,bloom:0});
        parentPort.postMessage({id:job.id,ok:true,result},[result.data.buffer]); return;
      }
      let cube=null;
      if(job.lutPath){if(!cubes.has(job.lutPath)){cubes.set(job.lutPath,parseCube(await fs.readFile(job.lutPath,'utf8')));if(cubes.size>4)cubes.delete(cubes.keys().next().value);}cube=cubes.get(job.lutPath);}
      let data,info;const a=cleanAdjustments(job.adjustments);
      if(job.kind==='auto-fit'){
        const source=await sharp(job.referenceInput,{limitInputPixels:150000000,failOn:'error'}).rotate().resize(320,320,{fit:'inside',withoutEnlargement:true}).flatten({background:'#ffffff'}).toColourspace('srgb').ensureAlpha().raw().toBuffer({resolveWithObject:true});
        // Meter the photograph, not its unexposed border or luminous date back.
        const plain={...a,autoFitMode:'off',autoFitEV:0,autoFitSaturation:1,grain:0,spectralEdge:false,spectralDate:false};
        let styled;
        if(plain.engine==='spectral'){
          spectral ||= new SpectralHost();const result=await spectral.render(job.input,plain,320);
          styled=Buffer.from(result.data);
        }else{
          styled=Buffer.from(source.data);applyPixels(styled,4,plain,cube);
        }
        const fit=AutoFit.derive(source.data,styled,4);
        // Check the real output path, not only a predicted curve in another
        // working space. Back off when a lift reduces measured tonal separation.
        for(let attempt=0;fit.ev>0&&attempt<4;attempt++){
          const trial={...plain,autoFitMode:'natural',autoFitVersion:2,autoFitEV:fit.ev,autoFitSaturation:1};
          let checked;
          if(plain.engine==='spectral')checked=(await spectral.render(job.input,trial,320)).data;
          else{checked=Buffer.from(source.data);applyPixels(checked,4,trial,cube);}
          if(AutoFit.safeBrightness(fit.styled,AutoFit.measure(checked,4)))break;
          fit.ev=attempt===3||fit.ev/2<.12?0:fit.ev/2;
        }
        parentPort.postMessage({id:job.id,ok:true,result:{...fit,ev:Math.round(fit.ev*10000)/10000,saturation:Math.round(fit.saturation*10000)/10000}});return;
      }
      if(job.export&&a.engine==='spectral'&&a.spectralVersion===2){
        spectral ||= new SpectralHost();
        const result=await spectral.exportImage(job.input,a,job.output,job.format,job.size,job.quality);
        parentPort.postMessage({id:job.id,ok:true,result});return;
      }
      if(job.format==='tiff')throw Error('16 位 TIFF 需要先将所选照片对齐新版光谱流程');
      if(a.engine==='spectral'){
        if(a.spectralVersion===2){
          spectral ||= new SpectralHost();const rendered=await spectral.renderManaged(job.input,a,job.size);
          await fs.writeFile(job.output,rendered.data);parentPort.postMessage({id:job.id,ok:true});return;
        }
        spectral ||= new SpectralHost();const rendered=await spectral.render(job.input,a,job.size);
        data=Buffer.from(rendered.data);info={width:rendered.width,height:rendered.height,channels:4};
        if(a.spectralVersion!==2)applyPixels(data,4,{...a,engine:'lut',lut:false,exposure:0,grain:0,halation:0,bloom:0});
      }else{
        ({data,info}=await sharp(job.input,{limitInputPixels:150000000,failOn:'error'}).rotate().resize(job.size,job.size,{fit:'inside',withoutEnlargement:true}).flatten({background:'#ffffff'}).toColourspace('srgb').removeAlpha().raw().toBuffer({resolveWithObject:true}));
        applyPixels(data,info.channels,a,cube);applyTexture(data,info.width,info.height,info.channels,a);
      }
      const image=sharp(data,{raw:{width:info.width,height:info.height,channels:info.channels}});
      if(job.export)image.withIccProfile('srgb');
      const format=String(job.format||'jpeg').toLowerCase(), quality=Number.isFinite(job.quality)?Math.max(1,Math.min(100,job.quality)):job.size>1600?94:88;
      if(format==='png') image.png(); else if(format==='webp') image.webp({quality}); else image.jpeg({quality});
      await image.toFile(job.output);
      parentPort.postMessage({id:job.id,ok:true});
    }catch(e){parentPort.postMessage({id:job.id,error:e.message});}
  });
});
