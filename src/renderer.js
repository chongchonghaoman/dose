import { LivePreview } from './live-preview.js';
import { ShareComposer } from './share-composer.js';
import { PhotoView } from './photo-view.js';
import { LutBrowser } from './lut-browser.js';
const $ = s => document.querySelector(s);
const api = window.lighttable;
const canvas = $('#table'), ctx = canvas.getContext('2d', { alpha: false, colorSpace:'display-p3' }), stage = $('#stage');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
let state, W = 1, H = 1, dpr = 1, ready = false, drawPending = false, saveTimer, toastTimer, busy = false;
let librarySelected=new Set(),photoExporting=false;
let uiPreferences={favoriteLuts:[],librarySort:'added'},librarySearchTimer;
const filenameOrder=new Intl.Collator('zh-CN',{numeric:true,sensitivity:'base'});
let selected = new Set(), tool = 'pointer', close = false, pointer = { x: 0, y: 0, inside: false }, drag = null, selectionRect = null;
let history = [], future = [], lamp = 1, flash = 0, lampStart = 0, lensDiameter = 260, lensMag = 1.5, animationTime = 0,viewportTimer;
let slidePhotos = [], slideIndex = 0, slideToken = 0, projecting = false, shuffled = false, audioContext;
const images = new Map(), photoMap = new Map(),thumbnailImages=new Map();
const clamp = (v,a,b) => Math.max(a,Math.min(b,v));
const uid = () => crypto.randomUUID();
const DEFAULT_ADJUSTMENTS=globalThis.LightTableFilm.DEFAULTS;
// Legacy spectral recipes remain readable; new adjustments use the LUT path.
const adjustmentOf=id=>({...DEFAULT_ADJUSTMENTS,...(photoMap.get(id)?.adjustments||{})});
const photoURL = (id,size='preview',original=false) => { const a=adjustmentOf(id); const edit=original?'':`&edit=${encodeURIComponent(JSON.stringify(a))}`; const lutId=original?'':(a.lutId||filmStatus?.hash||''); const hash=lutId?`&lutHash=${encodeURIComponent(lutId)}`:''; return `photo://${id}/image?size=${size}${edit}${hash}`; };
let filmStatus={available:false,name:'本地胶片库未安装',hash:'',library:[]}, filmOriginal=false, filmDebounce, filmGesture=null;

const liveFrames=new Map(),spectralFrames=new Map(),spectralSeq=new Map(),spectralPending=new Map(),spectralRunning=new Set();let liveRaf=0,liveIds=[],liveErrorShown=false;
const autoFitPending=new Map(),autoFitRunning=new Map(),autoFitFailed=new Map();let autoFitTimer;
const shareComposer=new ShareComposer({api,getScene:()=>structuredClone({photos:state.photos.map(p=>({...p,adjustments:adjustmentOf(p.id)})),items:state.items,layoutStyle:state.layoutStyle}),getSource:(p,size)=>`photo://${p.id}/image?size=${size}&edit=${encodeURIComponent(JSON.stringify(p.adjustments))}&lutHash=${encodeURIComponent(p.adjustments?.lutId||filmStatus.hash||'')}`,getFallback:p=>{const im=thumbnailImages.get(p.id);return im?.naturalWidth?im:null;},notify:message=>toast(message)});
const photoView=new PhotoView({canvas,redraw:requestDraw,onZoom:updateControls,onClose:()=>setPhotoView(false),onNavigate:navigatePhoto});
const lutBrowser=new LutBrowser({getContext:()=>{const id=photoView.id||filmTargets()[0];return {photo:photoMap.get(id),adjustments:adjustmentOf(id),library:filmStatus.library||[],favorites:uiPreferences.favoriteLuts};},onChoose:chooseLut,onFavorite:async hash=>{const list=uiPreferences.favoriteLuts;await savePreferences({favoriteLuts:list.includes(hash)?list.filter(id=>id!==hash):[...list,hash]});}});
async function savePreferences(patch){const previous=uiPreferences;uiPreferences={...uiPreferences,...patch};try{uiPreferences=await api.savePreferences(patch);}catch{uiPreferences=previous;$('#library-sort').value=previous.librarySort;renderLibrary();toast('偏好保存失败，请检查磁盘空间。');}}
function visibleLibraryPhotos(){
  if(!state)return [];const q=$('#library-search').value.trim().normalize('NFKC').toLocaleLowerCase(),filter=$('#library-filter').value,sort=$('#library-sort').value,placed=new Set(state.items.map(i=>i.photoId));
  const photos=state.photos.filter(p=>(!q||p.name.normalize('NFKC').toLocaleLowerCase().includes(q))&&(filter==='placed'?placed.has(p.id):filter==='unplaced'?!placed.has(p.id):true));
  if(sort!=='added')photos.sort((a,b)=>(sort==='name-desc'?-1:1)*filenameOrder.compare(a.name,b.name));return photos;
}
function applyLibraryFilter(){
  clearTimeout(librarySearchTimer);finishFilmGesture();const ids=new Set(visibleLibraryPhotos().map(p=>p.id));
  librarySelected=new Set([...librarySelected].filter(id=>ids.has(id)));selected=new Set([...selected].filter(id=>ids.has(state.items.find(i=>i.id===id)?.photoId)));
  renderLibrary();updateControls();requestDraw();
}
function setPhotoView(open){
  finishFilmGesture();const ids=filmTargets();if(open&&ids.length)photoView.show(ids.includes(photoView.id)?photoView.id:ids[0]);else photoView.hide();
  updateControls();requestDraw();
}
function navigatePhoto(direction){
  const photos=visibleLibraryPhotos(),index=photos.findIndex(p=>p.id===photoView.id),photo=photos[index<0?0:index+direction];if(!photo)return;
  finishFilmGesture();librarySelected=new Set([photo.id]);selected=new Set(state.items.filter(i=>i.photoId===photo.id).map(i=>i.id));photoView.show(photo.id);updateControls();requestDraw();
  document.querySelector('.film-thumb[data-id="'+photo.id+'"]')?.scrollIntoView({block:'nearest',inline:'nearest'});
}
function fitRecipe(a){return JSON.stringify(a.engine==='spectral'?['natural-v2','spectral',a.spectralFilm,a.spectralPaper,a.filmFormat,a.metering]:['natural-v2','lut',a.lutId||filmStatus.hash,a.lut,a.strength]);}
function queueAutoFit(ids,force=false){
  if(!ready)return;const targets=new Set(filmTargets());
  for(const id of ids){const a=adjustmentOf(id);if(!targets.has(id)||a.autoFitMode!=='natural'||(a.engine!=='spectral'&&(!a.lut||a.strength<=0)))continue;const key=fitRecipe(a);if(!force&&(autoFitRunning.get(id)===key||autoFitFailed.get(id)===key))continue;if(force||a.autoFitKey!==key)autoFitPending.set(id,{key,force});}
  clearTimeout(autoFitTimer);autoFitTimer=undefined;if(autoFitPending.size)autoFitTimer=setTimeout(runAutoFit,180);
}
async function runAutoFit(){
  autoFitTimer=undefined;
  for(const [id,job]of [...autoFitPending]){
    if(autoFitRunning.has(id))continue;autoFitPending.delete(id);const a=adjustmentOf(id);
    if(!filmTargets().includes(id)||a.autoFitMode!=='natural'||fitRecipe(a)!==job.key)continue;
    autoFitRunning.set(id,job.key);updateFilmPanel();
    try{const result=await api.autoFit({id,adjustments:a});const current=adjustmentOf(id);
      if(filmTargets().includes(id)&&current.autoFitMode==='natural'&&fitRecipe(current)===job.key){
        // Keep the baseline measured when this request began. A manual slider
        // moved during analysis remains an edit on top, without starting a loop.
        autoFitFailed.delete(id);const p=photoMap.get(id);p.adjustments={...p.adjustments,autoFitEV:result.ev,autoFitSaturation:result.saturation,autoFitKey:job.key};queueLive([id]);changed(true);
      }
    }catch(e){autoFitFailed.set(id,job.key);toast('这张照片暂时无法自动适配，已保留当前效果。');console.warn('Auto fit:',e);}
    finally{autoFitRunning.delete(id);updateFilmPanel();}
  }
  if(autoFitPending.size&&!autoFitTimer)autoFitTimer=setTimeout(runAutoFit,180);
}
const liveSignature=id=>JSON.stringify(adjustmentOf(id))+':'+(adjustmentOf(id).lutId||filmStatus.hash);
const spectralSignature=id=>JSON.stringify(adjustmentOf(id));
const livePreview=new LivePreview({loadLut:hash=>api.previewLut(hash),onFrame:(id,frame)=>{
  const old=liveFrames.get(id);old?.image?.close();old?.bloom?.close();liveFrames.set(id,frame);
  while(liveFrames.size>12){const key=liveFrames.keys().next().value,value=liveFrames.get(key);value.image.close();value.bloom?.close();liveFrames.delete(key);}
  canvas.dataset.liveFrames=String(Number(canvas.dataset.liveFrames||0)+1);canvas.dataset.liveSignature=frame.signature;
  if(filmGesture&&!filmOriginal){const thumb=$(`.film-thumb[data-id="${id}"] .sleeve-thumb`);if(thumb){let c=thumb.querySelector('canvas');if(!c){c=document.createElement('canvas');c.className='live-thumb';thumb.append(c);}c.width=frame.image.width;c.height=frame.image.height;c.getContext('2d').drawImage(frame.image,0,0);thumb.querySelector('img').style.visibility='hidden';}}
  requestDraw();
},onError:error=>{if(!liveErrorShown){liveErrorShown=true;toast('实时预览暂不可用，松开后会更新完整画质。');}console.warn('Live preview:',error.message);}});
function previewTargets(ids){const view={x:world({x:0,y:0}).x,y:world({x:0,y:0}).y,w:W/state.camera.zoom,h:H/state.camera.zoom};const onstage=new Set(state.items.filter(i=>visible(bounds(i),view)).map(i=>i.photoId));const priority=photoView.open&&ids.includes(photoView.id)?[photoView.id]:[];return [...new Set([...priority,...ids.filter(id=>onstage.has(id)),...ids.filter(id=>!onstage.has(id))])].slice(0,12);}
function queueLive(ids){queueAutoFit(ids);liveIds=previewTargets(ids);const spectral=liveIds.filter(id=>adjustmentOf(id).engine==='spectral');for(const id of spectral){spectralPending.set(id,{adjustments:adjustmentOf(id),signature:spectralSignature(id)});if(!spectralRunning.has(id))requestSpectral(id);}const lut=liveIds.filter(id=>adjustmentOf(id).engine!=='spectral');if(!lut.length)return;if(liveRaf)return;liveRaf=requestAnimationFrame(()=>{liveRaf=0;livePreview.request(lut.map(id=>{const a=adjustmentOf(id);return {id,url:photoURL(id,'800',true),adjustments:a,lutHash:a.lut?(a.lutId||filmStatus.hash):'',signature:liveSignature(id)};}));});}
async function requestSpectral(id){if(spectralRunning.has(id))return;spectralRunning.add(id);try{while(spectralPending.has(id)){const pending=spectralPending.get(id);spectralPending.delete(id);const signature=pending.signature,seq=(spectralSeq.get(id)||0)+1;spectralSeq.set(id,seq);try{const result=await api.spectralPreview({id,adjustments:pending.adjustments,signature});const bytes=result?.data instanceof Uint8Array?result.data:new Uint8Array(result?.data||[]);if(!result?.width||!result?.height||!bytes.length||(result.encoding!=='png'&&bytes.length!==result.width*result.height*4))throw new Error('光谱引擎返回了无效图像');const image=result.encoding==='png'?await createImageBitmap(new Blob([bytes],{type:'image/png'})):await createImageBitmap(new ImageData(new Uint8ClampedArray(bytes),result.width,result.height));const current=spectralSignature(id)===signature;const gesture=filmGesture?.ids.includes(id)&&adjustmentOf(id).engine==='spectral';if(spectralSeq.get(id)!==seq||(!current&&!gesture)){image.close();continue;}const old=spectralFrames.get(id);old?.image?.close();spectralFrames.set(id,{image,signature});canvas.dataset.spectralFrames=String(Number(canvas.dataset.spectralFrames||0)+1);canvas.dataset.spectralEncoding=result.encoding||'rgba8';requestDraw();}catch(error){if(spectralSeq.get(id)===seq)toast('光谱预览失败：'+(error?.message||'未知错误')+'，已保留当前图像。');console.warn('Spectral preview:',error);}}}finally{spectralRunning.delete(id);if(spectralPending.has(id))requestSpectral(id);}}
function finishFilmGesture(){if(!filmGesture)return;const ids=filmGesture.ids;filmGesture=null;queueLive(ids);changed(true);}
const pad = n => String(n).padStart(2,'0');
function toast(message, duration=5000) { clearTimeout(toastTimer); $('#toast span').textContent=message; $('#toast').hidden=false; toastTimer=setTimeout(()=>$('#toast').hidden=true,duration); }
$('#toast button').onclick=()=>$('#toast').hidden=true;
function snapshot() { return JSON.stringify({ items:state.items, editorialPages:state.editorialPages, editorialRevision:state.editorialRevision,momentsRevision:state.momentsRevision,viewportRevision:state.viewportRevision, photoAdjustments:state.photos.map(p=>[p.id,p.adjustments]), camera:state.camera,layoutStyle:state.layoutStyle }); }
function checkpoint() { history.push(snapshot()); if(history.length>40) history.shift(); future=[]; }
function undo(redo=false) { const source=redo?future:history, dest=redo?history:future; if(!source.length)return; dest.push(snapshot()); const next=JSON.parse(source.pop()); state.items=next.items;state.editorialPages=next.editorialPages||[];state.editorialRevision=next.editorialRevision||0;state.momentsRevision=next.momentsRevision||0;state.viewportRevision=next.viewportRevision||0;state.camera=next.camera;state.layoutStyle=next.layoutStyle||'editorial';for(const [id,a] of (next.photoAdjustments||[])){const p=photoMap.get(id);if(p)p.adjustments={...DEFAULT_ADJUSTMENTS,...(a||{})};} selected.clear();librarySelected.clear();if(photoView.open&&state.photos.some(p=>p.id===photoView.id)){librarySelected.add(photoView.id);selected=new Set(state.items.filter(i=>i.photoId===photoView.id).map(i=>i.id));} rebuild(); changed(true); }
function showSaveStatus(status,text){const el=$('#save-state');el.dataset.state=status;el.textContent=text;el.title=text;}
function scheduleSave() { clearTimeout(saveTimer);showSaveStatus('saving','正在保存');saveTimer=setTimeout(flush,350); }
async function flush() { if(!state)return; clearTimeout(saveTimer); try { await api.save(state); showSaveStatus('saved','已保存在本机'); } catch { showSaveStatus('error','保存失败'); toast('布局保存失败。请导出布局备份，并检查磁盘空间。'); } }
function changed(library=false) { const ids=new Set(state.items.map(i=>i.id));state.editorialPages=(state.editorialPages||[]).map(p=>({...p,itemIds:p.itemIds.filter(id=>ids.has(id))})).filter(p=>p.itemIds.length);updateControls(); if(library) renderLibrary(); requestDraw(); scheduleSave(); }
function world(p) { return {x:(p.x-W/2-state.camera.x)/state.camera.zoom,y:(p.y-H/2-state.camera.y)/state.camera.zoom}; }
function screen(p) { return {x:W/2+state.camera.x+p.x*state.camera.zoom,y:H/2+state.camera.y+p.y*state.camera.zoom}; }
function geometry(item) { const p=photoMap.get(item.photoId),a=adjustmentOf(item.photoId),native=p?.nativeFrame||(!filmOriginal&&a.engine==='spectral'&&a.spectralVersion===2&&a.spectralEdge);const frame=spectralFrames.get(item.photoId),image=native&&frame?.signature===spectralSignature(item.photoId)?frame.image:null;const w=item.width,h=w*(native&&item.presentation!=='print'&&image?(image.naturalHeight||image.height)/(image.naturalWidth||image.width):(p?.height||1000)/(p?.width||1500));return DoseFilmFrame.metrics(w,h,native||item.presentation==='print'?'bare':item.mount,!native&&item.presentation!=='print'&&item.sprockets!==false); }
function bounds(item) { const g=geometry(item),a=item.angle*Math.PI/180,c=Math.abs(Math.cos(a)),s=Math.abs(Math.sin(a)); return { x:item.x-(g.ow*c+g.oh*s)/2, y:item.y-(g.oh*c+g.ow*s)/2, w:g.ow*c+g.oh*s,h:g.oh*c+g.ow*s }; }
function hit(p) { const q=world(p); return [...state.items].reverse().find(i=>{ const g=geometry(i),a=-i.angle*Math.PI/180,dx=q.x-i.x,dy=q.y-i.y,x=dx*Math.cos(a)-dy*Math.sin(a),y=dx*Math.sin(a)+dy*Math.cos(a); return Math.abs(x)<=g.ow/2&&Math.abs(y)<=g.oh/2; }); }
function getImage(id,full=false,size=1600) {
  const a=adjustmentOf(id),spectral=!filmOriginal&&a.engine==='spectral'?spectralFrames.get(id):null,matchingSpectral=spectral?.signature===spectralSignature(id)?spectral:null;
  const live=!filmOriginal&&a.engine!=='spectral'?liveFrames.get(id):null,matching=live?.signature===liveSignature(id)?live:null;
  const previous=[...images].filter(([key,v])=>key.startsWith(id+':')&&key.includes(':original='+filmOriginal)&&v.image?.naturalWidth>0).sort((a,b)=>b[1].used-a[1].used)[0]?.[1];
  const fallback=matchingSpectral||matching||previous;
  if(!filmOriginal&&filmGesture?.ids.includes(id)){
    if(a.engine==='spectral'&&spectral)return spectral;
    if(live)return live;
    const previous=[...images].filter(([key,v])=>key.startsWith(id+':')&&v.image?.naturalWidth>0).sort((a,b)=>b[1].used-a[1].used)[0]?.[1];if(previous)return previous;
  }
  const key=id+':'+size+':'+JSON.stringify(adjustmentOf(id))+':'+(filmStatus.hash||'')+':original='+filmOriginal+(full?':full':'');
  if(images.has(key)) { const v=images.get(key); v.used=performance.now(); return v.image?v:fallback||v; }
  const entry={ image:null,bloom:null,missing:false,used:performance.now() }; images.set(key,entry);
  let settled;entry.ready=new Promise(resolve=>{settled=resolve;});
  const im=new Image(); im.decoding='async';im.crossOrigin='anonymous';
  im.onload=()=>{
    entry.image=im;
    if(!full&&size>=320){
      const c=document.createElement('canvas'); c.width=240; c.height=Math.max(1,Math.round(240*im.naturalHeight/im.naturalWidth));
      const x=c.getContext('2d',{willReadFrequently:true}); x.drawImage(im,0,0,c.width,c.height);
      try { const data=x.getImageData(0,0,c.width,c.height); for(let k=0;k<data.data.length;k+=4){ const l=Math.max(data.data[k],data.data[k+1],data.data[k+2])/255; data.data[k+3]=Math.round(Math.pow(Math.max(0,(l-.65)/.35),2)*80); } x.putImageData(data,0,0); entry.bloom=c; } catch {}
    }
    const entries=[...images].filter(([k,v])=>(full?k.endsWith(':full'):!k.endsWith(':full'))&&v.image).sort((a,b)=>a[1].used-b[1].used);
    let pixels=entries.reduce((sum,[k,v])=>sum+v.image.naturalWidth*v.image.naturalHeight,0);
    while(entries.length>1&&(full?entries.length>2:pixels>52000000)){const [oldKey,old]=entries.shift();pixels-=old.image.naturalWidth*old.image.naturalHeight;old.image.src='';images.delete(oldKey);}
    settled();requestDraw();
  };
  im.onerror=()=>{entry.missing=true;settled();toast('这张照片暂时无法更新，已保留可用预览。请检查原文件路径。');requestDraw();}; im.src=photoURL(id,full?'full':String(size),filmOriginal); return fallback||entry;
}
async function warmPhotos(photos){for(let i=0;i<Math.min(64,photos.length);i+=8)await Promise.all(photos.slice(i,i+8).map(p=>getImage(p.id,false,320).ready));}
function rounded(x,y,w,h,r=2){ ctx.beginPath();ctx.roundRect(x,y,w,h,r); }
function visible(b,view) { return b.x+b.w>=view.x && b.x<=view.x+view.w && b.y+b.h>=view.y && b.y<=view.y+view.h; }
function drawEditorialPages(view){
  const pages=state.editorialPages||[];canvas.dataset.editorialPages=String(pages.length);canvas.dataset.editorialRevision=String(state.editorialRevision||0);
  for(const page of pages){
    if(!visible({x:page.x,y:page.y,w:page.width,h:page.height},view))continue;
    const s=page.width/849,x=page.x,y=page.y;
    ctx.save();ctx.shadowColor='#11170f28';ctx.shadowBlur=12;ctx.shadowOffsetY=3;
    ctx.fillStyle=lamp>.3?'#e8e6e3':'#555650';ctx.fillRect(x,y,page.width,page.height);ctx.shadowColor='transparent';
    if(page.kind==='viewport'){
      const z=state.camera.zoom,fy=y+page.height-16/z;
      ctx.fillStyle=lamp>.3?'#737a7c':'#a6aaa0';ctx.font=`${8/z}px "Segoe UI",sans-serif`;ctx.textBaseline='alphabetic';ctx.textAlign='left';ctx.fillText('VOLUME I',x+20/z,fy);ctx.textAlign='right';ctx.fillText('DOSE / PHOTO JOURNAL',x+page.width-48/z,fy);ctx.fillText(String(page.number),x+page.width-20/z,fy);ctx.restore();continue;
    }
    ctx.fillStyle=lamp>.3?'#737a7c':'#a6aaa0';ctx.font=`${11*s}px "Segoe UI",sans-serif`;ctx.textBaseline='alphabetic';ctx.textAlign='left';ctx.fillText('VOLUME I',x+40*s,y+1154*s);
    ctx.textAlign='right';ctx.fillText('DOSE / PHOTO JOURNAL',x+762*s,y+1154*s);ctx.fillText(String(page.number),x+807*s,y+1154*s);
    ctx.strokeStyle=lamp>.3?'#7d8383':'#a6aaa0';ctx.lineWidth=.7*s;ctx.beginPath();ctx.moveTo(x+778*s,y+1139*s);ctx.lineTo(x+778*s,y+1160*s);ctx.stroke();
    ctx.restore();
  }
}
function drawSleeves(view) {
  const groups=new Map(); for(const i of state.items)if(i.group){if(!groups.has(i.group))groups.set(i.group,[]);groups.get(i.group).push(i);}
  for(const [id,items] of groups){
    const boxes=items.map(bounds),x=Math.min(...boxes.map(b=>b.x))-40,y=Math.min(...boxes.map(b=>b.y))-38,r=Math.max(...boxes.map(b=>b.x+b.w))+25,bottom=Math.max(...boxes.map(b=>b.y+b.h))+27,w=r-x,h=bottom-y;
    if(!visible({x,y,w,h},view))continue;
    ctx.save();ctx.shadowColor='#00000023';ctx.shadowBlur=9;ctx.shadowOffsetY=4;ctx.fillStyle='rgba(245,245,235,.16)';rounded(x,y,w,h,3);ctx.fill();ctx.shadowColor='transparent';ctx.strokeStyle='#ffffff70';ctx.lineWidth=1/state.camera.zoom;ctx.stroke();
    ctx.fillStyle='#e7e9de50';ctx.fillRect(x+4,y+2,18,h-4);ctx.strokeStyle='#666b5e44';ctx.beginPath();ctx.moveTo(x+23,y);ctx.lineTo(x+23,bottom);ctx.stroke();
    for(let hole=0;hole<3;hole++){ctx.fillStyle=lamp>.4?'#a7ac9c':'#55594d';ctx.beginPath();ctx.ellipse(x+12,y+28+(h-56)*hole/2,3,5,0,0,Math.PI*2);ctx.fill();}
    ctx.fillStyle=lamp>.4?'#73796a':'#9b9d8c';ctx.font='8px Consolas';ctx.fillText('ARCHIVAL / LIGHTTABLE',x+34,y+16);
    for(const i of items){const g=geometry(i);ctx.strokeStyle='#ffffff85';ctx.strokeRect(i.x-g.ow/2-9,i.y-g.oh/2-10,g.ow+18,g.oh+20);ctx.strokeStyle='#777d6340';ctx.beginPath();ctx.moveTo(i.x-g.ow/2-9,i.y-g.oh/2-7);ctx.lineTo(i.x+g.ow/2+9,i.y-g.oh/2-7);ctx.stroke();}
    ctx.restore();
  }
}
function drawScene(view, lens=false, highId=null, magnification=1) {
  drawEditorialPages(view);
  drawSleeves(view);
  for(const item of state.items){
    const b=bounds(item);if(!visible(b,view))continue;
    const p=photoMap.get(item.photoId),g=geometry(item); if(!p)continue;
    const pixelSize=Math.max(g.w,g.h)*state.camera.zoom*dpr*magnification;
    const bucket=[48,96,320,800,1600].find(s=>s>=pixelSize)||1600;
    const preview=getImage(p.id,false,bucket),full=highId===p.id?getImage(p.id,true):null,entry=full?.image?full:preview;
    // A photograph enters the canvas only when pixels are ready; never draw a loading card.
    if(!entry.image&&!entry.missing)continue;
    ctx.save();ctx.translate(item.x,item.y);ctx.rotate(item.angle*Math.PI/180);
    ctx.shadowColor=item.presentation==='print'?'transparent':'#13190f55';ctx.shadowBlur=lens?2:3;ctx.shadowOffsetX=1;ctx.shadowOffsetY=1.8;
    if(g.film){const a=adjustmentOf(p.id);DoseFilmFrame.paint(ctx,g,{lamp,labels:pixelSize>=60,number:state.photos.indexOf(p)+1,stock:a.engine==='spectral'?(a.spectralFilm||'DOSE').replaceAll('_',' ').toUpperCase():'DOSE'});}else{ctx.fillStyle=lamp>.3?'#22261d':'#11150f';ctx.fillRect(-g.ow/2,-g.oh/2,g.ow,g.oh);}ctx.shadowColor='transparent';
    if(g.border){
      const grad=ctx.createLinearGradient(-g.ow/2,-g.oh/2,g.ow/2,g.oh/2);grad.addColorStop(0,lamp>.3?'#eeeadd':'#7c7c6e');grad.addColorStop(1,lamp>.3?'#d3d0c2':'#595b50');ctx.fillStyle=grad;rounded(-g.ow/2,-g.oh/2,g.ow,g.oh,2);ctx.fill();
      ctx.fillStyle=lamp>.3?'#8d8c7d':'#33382c';ctx.font=`${Math.max(5,g.border*.25)}px Consolas`;ctx.textAlign='left';ctx.fillText('LIGHTTABLE  /  REVERSAL',-g.w/2,-g.h/2-g.border*.4);ctx.textAlign='right';ctx.fillText(pad(state.photos.indexOf(p)+1),g.w/2,g.h/2+g.border*.65);
      ctx.fillStyle='#171b15';ctx.fillRect(-g.w/2-1,-g.h/2-1,g.w+2,g.h+2);
    }
    if(entry.image){
      const keepEdge=!filmOriginal&&adjustmentOf(p.id).engine==='spectral'&&adjustmentOf(p.id).spectralEdge;
      const iw=entry.image.naturalWidth||entry.image.width,ih=entry.image.naturalHeight||entry.image.height;
      const scale=keepEdge?Math.min(g.w/iw,g.h/ih):1,dw=keepEdge?iw*scale:g.w,dh=keepEdge?ih*scale:g.h;
      ctx.drawImage(entry.image,-dw/2,-dh/2,dw,dh);
      if(state.transmission){
        const dark=1-(.035+lamp*.965);ctx.fillStyle=`rgba(7,10,5,${clamp(dark,0,.97)})`;ctx.fillRect(-g.w/2,-g.h/2,g.w,g.h);
        const gain=state.brightness;
        if(lamp>.01&&gain<1){ctx.fillStyle=`rgba(0,0,0,${(1-gain)*lamp*.75})`;ctx.fillRect(-g.w/2,-g.h/2,g.w,g.h);}
        // Native film already includes optical effects. The lighttable must
        // display those pixels without a second, display-only bloom pass.
        if(lamp>.01&&(gain>1||flash>.01)){ctx.save();ctx.globalCompositeOperation='screen';ctx.globalAlpha=lamp*(Math.max(0,gain-1)*.22+flash*.2);ctx.drawImage(entry.image,-dw/2,-dh/2,dw,dh);ctx.restore();}
      }
    }else{
      ctx.fillStyle='#514a39';ctx.fillRect(-g.w/2,-g.h/2,g.w,g.h);ctx.fillStyle='#e4e2d1';ctx.textAlign='center';ctx.font='11px "Segoe UI"';ctx.fillText('原照片不可用',0,-3);ctx.font='8px "Segoe UI"';ctx.fillText('请将原文件放回导入路径',0,14);
    }
    if(item.presentation!=='print'){ctx.lineWidth=.65/state.camera.zoom;ctx.strokeStyle='#ffffff35';ctx.beginPath();ctx.moveTo(-g.ow/2,g.oh/2);ctx.lineTo(-g.ow/2,-g.oh/2);ctx.lineTo(g.ow/2,-g.oh/2);ctx.stroke();}
    if(selected.has(item.id)&&!lens){ctx.strokeStyle='#796746';ctx.lineWidth=1.5/state.camera.zoom;ctx.setLineDash([]);ctx.strokeRect(-g.ow/2-4/state.camera.zoom,-g.oh/2-4/state.camera.zoom,g.ow+8/state.camera.zoom,g.oh+8/state.camera.zoom);ctx.fillStyle='#ffffff';for(const sx of [-1,1])for(const sy of [-1,1])ctx.fillRect(sx*g.ow/2-2/state.camera.zoom,sy*g.oh/2-2/state.camera.zoom,4/state.camera.zoom,4/state.camera.zoom);}
    ctx.restore();
  }
}
function panelColor() { const brightness=.72+.28*Math.min(1,state.brightness);const gray=Math.round(55+(244*brightness-55)*lamp+flash*10);return `rgb(${gray},${gray},${gray})`; }
function baseScene(mag=1,center=null,lens=false,highId=null){
  ctx.save();
  if(center){ctx.translate(center.x,center.y);ctx.scale(mag,mag);ctx.translate(-center.x,-center.y);}
  ctx.translate(W/2+state.camera.x,H/2+state.camera.y);ctx.scale(state.camera.zoom,state.camera.zoom);
  const top=world(center?{x:center.x-center.r/mag,y:center.y-center.r/mag}:{x:0,y:0});
  drawScene({x:top.x,y:top.y,w:(center?center.r*2/mag:W)/state.camera.zoom,h:(center?center.r*2/mag:H)/state.camera.zoom},lens,highId,mag);
  ctx.restore();
}
function draw(now=performance.now()){
  drawPending=false;if(!ready||projecting)return;
  if(photoView.open){photoView.update(photoMap.get(photoView.id),visibleLibraryPhotos(),filmOriginal);const frame=getImage(photoView.id,photoView.zoom>1,1600);photoView.paint(ctx,W,H,dpr,frame);return;}
  canvas.dataset.view='table';
  const dt=Math.min(50,now-animationTime||16);animationTime=now;
  let animate=false;
  const target=state.lit?1:0;
  if(Math.abs(lamp-target)>.001){lamp+=(target-lamp)*(reduced?1:1-Math.exp(-dt/140));animate=true;}else lamp=target;
  flash=state.lit&&!reduced?Math.max(0,1-(now-lampStart)/620)*.55:0;if(flash>0)animate=true;
  ctx.setTransform(dpr,0,0,dpr,0,0);ctx.fillStyle=panelColor();ctx.fillRect(0,0,W,H);
  const glow=ctx.createRadialGradient(W*.48,H*.44,0,W*.5,H*.5,Math.max(W,H)*.68);glow.addColorStop(0,'#ffffff12');glow.addColorStop(.65,'#ffffff00');glow.addColorStop(1,'#0000000a');ctx.fillStyle=glow;ctx.fillRect(0,0,W,H);
  baseScene();
  if(selectionRect){const r=selectionRect;ctx.fillStyle='#79674620';ctx.fillRect(r.x,r.y,r.w,r.h);ctx.strokeStyle='#796746';ctx.lineWidth=1;ctx.strokeRect(r.x,r.y,r.w,r.h);}
  canvas.dataset.loupeVisible=String(tool==='loupe'&&pointer.inside);
  if(tool==='loupe'&&pointer.inside){
    const targetD=close?Math.max(260,Math.min(W,H)*.9):230;
    const hovered=hit(pointer),g=hovered?geometry(hovered):null,p=hovered?photoMap.get(hovered.photoId):null;
    const natural=g&&p?clamp(p.width/(g.w*state.camera.zoom),1.5,24):3;
    const targetM=close?(state.closeMode==='8'?8:natural):1.5;
    lensDiameter+=(targetD-lensDiameter)*(reduced?1:1-Math.exp(-dt/85));lensMag+=(targetM-lensMag)*(reduced?1:1-Math.exp(-dt/90));
    if(Math.abs(targetD-lensDiameter)>.2||Math.abs(targetM-lensMag)>.01)animate=true;
    const r=lensDiameter/2,c={x:clamp(pointer.x,r+13,W-r-13),y:clamp(pointer.y,r+13,H-r-13),r};
    // Shift optical source with the ring near the edge, preserving exact pointer alignment in the central region.
    ctx.save();ctx.shadowColor='#070b0466';ctx.shadowBlur=24;ctx.shadowOffsetY=10;ctx.fillStyle='#292c25';ctx.beginPath();ctx.arc(c.x,c.y,r+9,0,Math.PI*2);ctx.fill();ctx.restore();
    ctx.save();ctx.beginPath();ctx.arc(c.x,c.y,r,0,Math.PI*2);ctx.clip();ctx.fillStyle=panelColor();ctx.fillRect(c.x-r,c.y-r,2*r,2*r);
    // Recenter sampling when the lens is clamped to the panel boundary.
    ctx.translate(c.x-pointer.x,c.y-pointer.y);baseScene(lensMag,{...pointer,r},true,close?hovered?.photoId:null);ctx.restore();
    const rim=ctx.createLinearGradient(c.x-r,c.y-r,c.x+r,c.y+r);rim.addColorStop(0,'#c4c6bd');rim.addColorStop(.18,'#6e7566');rim.addColorStop(.42,'#292f24');rim.addColorStop(.7,'#0d130a');rim.addColorStop(1,'#939b86');
    ctx.strokeStyle=rim;ctx.lineWidth=7;ctx.beginPath();ctx.arc(c.x,c.y,r+4,0,Math.PI*2);ctx.stroke();ctx.strokeStyle='#ffffff9c';ctx.lineWidth=1;ctx.beginPath();ctx.arc(c.x,c.y,r-1,Math.PI*1.05,Math.PI*1.8);ctx.stroke();
    const glass=ctx.createRadialGradient(c.x,c.y,r*.82,c.x,c.y,r);glass.addColorStop(0,'#ffffff00');glass.addColorStop(.75,'#ffffff08');glass.addColorStop(.94,'#ffffff32');glass.addColorStop(1,'#1d2b2250');ctx.fillStyle=glass;ctx.beginPath();ctx.arc(c.x,c.y,r,0,Math.PI*2);ctx.fill();
    ctx.fillStyle='#20251fec';rounded(c.x-31,c.y+r-32,62,21,10);ctx.fill();ctx.fillStyle='#e0dfcc';ctx.font='10px Consolas';ctx.textAlign='center';ctx.fillText(close?(state.closeMode==='8'?'8.0×':'原倍率'):'1.5×',c.x,c.y+r-18);
  }
  if(animate)requestDraw();
}
function requestDraw(){if(!drawPending){drawPending=true;requestAnimationFrame(draw);}}
function resize(){W=stage.clientWidth;H=stage.clientHeight;dpr=Math.min(2,devicePixelRatio||1);canvas.width=Math.round(W*dpr);canvas.height=Math.round(H*dpr);requestDraw();if(ready&&!photoView.open&&state.layoutStyle==='viewport'&&canvas.dataset.viewportSize!==W+'x'+H){clearTimeout(viewportTimer);viewportTimer=setTimeout(()=>{if(!photoView.open&&state.layoutStyle==='viewport')layoutViewportAll(false);},160);}}
new ResizeObserver(resize).observe(stage);
function selectedMagazinePage(){
  if(!selected.size)return null;
  return (state.editorialPages||[]).find(p=>p.kind!=='viewport'&&[...selected].every(id=>p.itemIds.includes(id)))||null;
}
function updateControls(){
  const targets=filmTargets();if(photoView.open){if(!targets.length)photoView.hide();else if(!targets.includes(photoView.id))photoView.show(targets[0]);}
  $('#empty-state').hidden=state.photos.length>0;const visiblePhotos=visibleLibraryPhotos();$('#library-count').textContent=visiblePhotos.length===state.photos.length?pad(state.photos.length):visiblePhotos.length+' / '+state.photos.length;
  $('#zoom-value').textContent=photoView.open?(photoView.zoom===1?'适应':photoView.zoom.toFixed(1)+'×'):Math.round(state.camera.zoom*100)+'%';
  for(const id of ['pointer','loupe','brightness','power'])$('#'+id).disabled=photoView.open;
  $('#focus-photo').disabled=!targets.length;$('#focus-photo').setAttribute('aria-pressed',String(photoView.open));
  $('#library-search-clear').hidden=!$('#library-search').value;$('#library-reset').hidden=!$('#library-search').value&&$('#library-filter').value==='all';
  $('#brightness').value=Math.round(state.brightness*100);$('#brightness-value').textContent=Math.round(state.brightness*100)+'%';
  $('#power').classList.toggle('active',state.lit);$('#power').setAttribute('aria-pressed',state.lit);$('#power span').textContent=state.lit?'灯已开启':'灯已关闭';
  $('#pointer').classList.toggle('active',tool==='pointer');$('#loupe').classList.toggle('active',tool==='loupe');$('#pointer').setAttribute('aria-pressed',tool==='pointer');$('#loupe').setAttribute('aria-pressed',tool==='loupe');$('#magnification').hidden=photoView.open||tool!=='loupe';$('#magnification').textContent='凑近 · '+(state.closeMode==='8'?'8×':'原倍率');
  canvas.style.cursor=tool==='loupe'?'none':drag?'grabbing':'default';
  const items=state.items.filter(i=>selected.has(i.id));$('#selection-bar').hidden=photoView.open||!items.length||tool==='loupe';$('#selection-name').textContent=items.length===1?photoMap.get(items[0].photoId)?.name:`已选择 ${items.length} 张`;
  const reflow=$('#reflow-page');reflow.hidden=!(state.editorialPages||[]).some(p=>p.kind!=='viewport'&&p.itemIds.some(id=>selected.has(id)));reflow.disabled=!selectedMagazinePage()||busy;reflow.title=reflow.disabled?'请选择同一杂志页内的照片':'重新编排本页全部照片，其他页面保持不变';
  $('#mount').textContent=items.length&&items.every(i=>i.presentation!=='print'&&i.mount==='slide')?'取消装框':'装框';
  $('#sprockets').setAttribute('aria-pressed',String(items.length>0&&items.every(i=>geometry(i).film)));
  for(const id of ['arrange','sleeve','slideshow'])$('#'+id).disabled=!state.photos.length||busy;
  $('#share-grid').disabled=!state.photos.length||busy;
  $('#auto-layout').title=state.layoutStyle==='moments'?'将胶片库全部照片编排成九页杂志，再点一次换一组':state.layoutStyle==='editorial'?'根据照片生成杂志构图，再点一次换一版':state.layoutStyle==='viewport'?'将全部照片排进当前窗口，窗口变化时自动重排':'整理所选照片，未选择时整理全部';$('#auto-layout').disabled=!state.photos.length||busy;$('#layout-style').disabled=!state.photos.length||busy;
  $('#layout-style').value=state.layoutStyle||'editorial';
  for(const id of ['import','import-folder','empty-import'])$('#'+id).disabled=busy;
  $('#sound span').textContent=state.sound?'机械声 开':'机械声 关';$('#sound').setAttribute('aria-pressed',state.sound);
  syncLibrarySelection();
  updateFilmPanel();
}
const filmFields=[['exposure','曝光','-2','2','0.01',' EV'],['highlights','高光','-100','100','0.1',''],['shadows','阴影','-100','100','0.1',''],['contrast','对比度','-100','100','0.1',''],['temperature','色温','-100','100','0.1',''],['saturation','饱和度','-100','100','0.1',''],['grain','颗粒','0','100','0.1','%'],['halation','卤光','0','100','0.1','%'],['bloom','柔光','0','100','0.1','%']];
function filmValue(key,value,suffix){return (value>0?'+':'')+Number(value.toFixed(2))+suffix;}
function filmTargets(){return librarySelected.size?[...librarySelected].filter(id=>photoMap.has(id)):[...new Set(state.items.filter(i=>selected.has(i.id)).map(i=>i.photoId))];}
function tiffCapable(id){const a=adjustmentOf(id);return a.engine==='spectral'&&a.spectralVersion>=2||photoMap.get(id)?.referenceDeveloped&&!globalThis.LightTableFilm.hasEdits(a);}
let lutOptionsKey='';
function updateFilmPanel(){
  if(!state)return;
  const ids=filmTargets(),first=adjustmentOf(ids[0]),values=ids.map(adjustmentOf),legacy=values.some(a=>a.engine==='spectral');
  $('#reference-editor').disabled=!ids.length;
  $('#browse-luts').disabled=!ids.length;
  $('#reference-editor').title=ids.length?'在显影室中处理原片':'选择照片';
  $('#film-scope').textContent=ids.length===1?photoMap.get(ids[0])?.name:ids.length?ids.length+' 张照片':'选择照片';
  $('#film-scope').title=$('#film-scope').textContent;
  $('#film-scope').hidden=photoView.open&&ids.length===1;
  const library=Array.isArray(filmStatus.library)?filmStatus.library:[];
  const valueFor=a=>a.engine==='spectral'?'__legacy':a.lut?(a.lutId||filmStatus.hash||''):'';
  const chosen=ids.length?valueFor(first):'',mixed=values.some(a=>valueFor(a)!==chosen),missing=!!chosen&&!chosen.startsWith('__')&&!library.some(l=>l.hash===chosen);
  const select=$('#lut-library'),optionsKey=JSON.stringify([library.map(l=>[l.hash,l.name,l.source,l.available]),mixed,legacy,missing?chosen:'']);
  if(optionsKey!==lutOptionsKey){
    lutOptionsKey=optionsKey;select.replaceChildren();
    const option=(value,label,disabled=false)=>{const o=document.createElement('option');o.value=value;o.textContent=label;o.disabled=disabled;return o;};
    select.append(option('','无风格'));
    if(mixed)select.append(option('__mixed','多种风格',true));
    if(legacy)select.append(option('__legacy','旧版显影',true));
    if(missing)select.append(option(chosen,'缺失的 LUT',true));
    const groups=new Map();for(const lut of library){let group=groups.get(lut.source);if(!group){group=document.createElement('optgroup');group.label=lut.source;groups.set(lut.source,group);select.append(group);}group.append(option(lut.hash,lut.name,lut.available===false));}
  }
  select.value=mixed?'__mixed':chosen;select.disabled=!ids.length;
  select.title=legacy?'选择 LUT 将替换旧版显影，可撤销':'胶片风格';
  const error=$('#lut-error');error.hidden=!missing;error.textContent=missing?'LUT 不在本机，请重新导入。':'';
  const strength=$('#lut-strength'),strengthMixed=values.some(a=>a.strength!==first.strength);
  strength.value=first.strength;strength.disabled=!ids.length||legacy||!values.every(a=>a.lut)||missing;
  $('#lut-strength-value').textContent=strengthMixed?'—':first.strength+'%';
  filmFields.forEach(([key,,,,,suffix])=>{const input=$('#film-'+key),output=$('#film-'+key+'-value');input.disabled=!ids.length||legacy;input.value=legacy?0:first[key];output.textContent=legacy?'—':values.some(a=>a[key]!==first[key])?'—':filmValue(key,first[key],suffix);});
  $('#film-original').disabled=!ids.length;$('#film-reset').disabled=!ids.length;
  queueAutoFit(ids);
  const fitPending=ids.some(id=>{const a=adjustmentOf(id);return a.autoFitMode==='natural'&&(a.engine==='spectral'||a.lut)&&(a.autoFitKey!==fitRecipe(a)||autoFitRunning.has(id)||autoFitPending.has(id));});
  $('#export-photos').disabled=!ids.length||photoExporting||fitPending;$('#export-photos').title=fitPending?'正在完成原有亮度处理':'';
  const tiff=$('#export-format option[value="tiff"]'),canTiff=ids.length>0&&ids.every(tiffCapable);
  tiff.disabled=!canTiff;if(!canTiff&&$('#export-format').value==='tiff')$('#export-format').value='jpeg';
  $('#export-format').disabled=!ids.length||photoExporting;
}
function applyFilmField(field,value){const ids=filmGesture?.ids||filmTargets();if(!ids.length)return;for(const id of ids){const p=photoMap.get(id);if(p)p.adjustments={...DEFAULT_ADJUSTMENTS,...(p.adjustments||{}),[field]:value};}changed(true);}
function beginFilmGesture(field){if(!filmGesture||filmGesture.field!==field){finishFilmGesture();checkpoint();filmGesture={field,ids:filmTargets()};}}
function liveInput(field,value){beginFilmGesture(field);for(const id of filmGesture.ids){const p=photoMap.get(id);if(p)p.adjustments={...DEFAULT_ADJUSTMENTS,...p.adjustments,[field]:value};}queueLive(filmGesture.ids);requestDraw();scheduleSave();}
function initFilmPanel(){for(const [k,label,min,max,step,suffix] of filmFields){const wrap=$(['grain','halation','bloom'].includes(k)?'#texture-sliders':'#film-sliders');const row=document.createElement('label');row.className='film-slider';row.innerHTML=`<span>${label}<output id="film-${k}-value">0${suffix}</output></span><input id="film-${k}" type="range" min="${min}" max="${max}" step="${step}" value="0">`;wrap.append(row);const input=row.querySelector('input');input.oninput=()=>{const v=Number(input.value);liveInput(k,v);row.querySelector('output').textContent=filmValue(k,v,suffix);};input.onchange=()=>{liveInput(k,Number(input.value));finishFilmGesture();};input.onpointercancel=finishFilmGesture;}}
function refreshFilmImages(){renderLibrary();requestDraw();}
function syncLibrarySelection(){const ids=new Set(filmTargets());document.querySelectorAll('.film-thumb').forEach(el=>{const active=ids.has(el.dataset.id);el.title=(photoMap.get(el.dataset.id)?.name||'')+(photoView.open?' · 单击切换照片':' · 拖到台面或双击放入');el.classList.toggle('selected',active);el.setAttribute('aria-pressed',String(active));});}
function renderLibrary(){
  const strip=$('#filmstrip'),scroll=strip.scrollLeft,previousThumbs=new Map([...strip.querySelectorAll('.film-thumb')].map(b=>[b.dataset.id,b.querySelector('img')]));strip.replaceChildren();
  const photos=visibleLibraryPhotos();$('#library-empty').hidden=!state.photos.length||!!photos.length;strip.hidden=!!state.photos.length&&!photos.length;
  if(!photos.length)return;
  const placed=new Set(state.items.map(i=>i.photoId));for(const id of thumbnailImages.keys())if(!photoMap.has(id))thumbnailImages.delete(id);
  for(const p of photos){const b=document.createElement('button');b.className='film-thumb'+(placed.has(p.id)?' placed':'');b.dataset.id=p.id;b.draggable=true;b.title=p.name+' · 拖到台面或双击放入';b.setAttribute('aria-label',p.name);
    const sleeve=document.createElement('div');sleeve.className='sleeve-thumb';const im=document.createElement('img'),old=previousThumbs.get(p.id);im.alt='';im.draggable=false;im.loading='lazy';
    const usable=old?.naturalWidth>0&&old.src.includes('edit=')!==filmOriginal;
    if(usable){old.style.visibility='visible';sleeve.append(old);thumbnailImages.set(p.id,old);im.loading='eager';}else sleeve.append(im);
    im.onload=()=>{if(!sleeve.isConnected)return;thumbnailImages.set(p.id,im);const existing=sleeve.querySelector('img');if(existing&&existing!==im)existing.replaceWith(im);else if(!existing)sleeve.prepend(im);sleeve.style.visibility='visible';};
    im.onerror=()=>{if(!usable){sleeve.style.visibility='visible';sleeve.title='原照片不可用';}};
    im.src=photoURL(p.id,'thumb',filmOriginal);
    if(placed.has(p.id)){const check=document.createElement('span');check.className='check';check.textContent='✓';sleeve.append(check);}
    const label=document.createElement('span');label.className='thumb-name';label.textContent=p.name;b.append(sleeve,label);
    b.ondragstart=e=>{e.dataTransfer.setData('application/x-lighttable-photo',p.id);e.dataTransfer.effectAllowed='copy';};
    b.ondblclick=()=>{if(!photoView.open)place(p.id);};b.onclick=e=>{finishFilmGesture();if(e.ctrlKey||e.metaKey){if(!librarySelected.size)librarySelected=new Set(filmTargets());librarySelected.has(p.id)?librarySelected.delete(p.id):librarySelected.add(p.id);}else librarySelected=new Set([p.id]);selected=new Set(state.items.filter(i=>librarySelected.has(i.photoId)).map(i=>i.id));updateControls();requestDraw();};
    b.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();if(photoView.open)b.click();else place(p.id);}else if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();e.stopPropagation();const target=e.key==='ArrowLeft'?b.previousElementSibling:b.nextElementSibling;if(target){target.focus();target.click();}}};strip.append(b);
  }strip.scrollLeft=scroll;syncLibrarySelection();
}
function place(id,point=null,record=true){
  librarySelected.clear();
  if(record)checkpoint();const p=photoMap.get(id),pos=point?world(point):world({x:W/2,y:H/2});
  const item={id:uid(),photoId:id,x:pos.x,y:pos.y,width:Math.min(280,280*p.width/p.height),angle:0,mount:state.mount||'bare',group:null};state.items.push(item);selected=new Set([item.id]);changed(true);
}
function fit(){if(state.layoutStyle==='viewport'){layoutViewportAll(false);return;}if(!state.items.length){state.camera={x:0,y:0,zoom:1};changed();return;}
  const boxes=[...state.items.map(bounds),...(state.editorialPages||[]).map(p=>({x:p.x,y:p.y,w:p.width,h:p.height}))],x=Math.min(...boxes.map(b=>b.x))-55,y=Math.min(...boxes.map(b=>b.y))-55,r=Math.max(...boxes.map(b=>b.x+b.w))+55,b=Math.max(...boxes.map(b=>b.y+b.h))+55;
  const z=clamp(Math.min((W-80)/(r-x),(H-75)/(b-y)),.05,1.8);state.camera={zoom:z,x:-(x+r)/2*z,y:-(y+b)/2*z};changed();
}
function arrange(){if(!state.photos.length)return;checkpoint();const n=state.photos.length,cols=Math.max(1,Math.round(Math.sqrt(n*W/Math.max(1,H)/1.4))),cellW=300,cellH=285;
  state.items=state.photos.map((p,k)=>({id:uid(),photoId:p.id,x:(k%cols)*cellW,y:Math.floor(k/cols)*cellH,width:Math.min(245,185*p.width/p.height),angle:0,mount:state.mount||'bare',group:null}));selected.clear();librarySelected.clear();fit();changed(true);
}
function autoLayout(style=state.layoutStyle||'editorial'){
  if(style==='moments'){layoutMomentsAll();return;}
  if(style==='viewport'){layoutViewportAll(true);return;}
  if(!state.photos.length)return;checkpoint();state.layoutStyle=style;
  if(!state.items.length)state.items=state.photos.map(p=>({id:uid(),photoId:p.id,x:0,y:0,width:245,angle:0,mount:'bare',sprockets:true,group:null}));
  const order=new Map(state.photos.map((p,k)=>[p.id,k]));
  const targets=(selected.size?state.items.filter(i=>selected.has(i.id)):state.items).slice().sort((a,b)=>order.get(a.photoId)-order.get(b.photoId));
  if(!targets.length)return;
  if(targets.length===1&&state.items.length>1){changed();toast('请选择两张以上照片，或点击空白处排列全部。');return;}
  const targetIds=new Set(targets.map(i=>i.id)),oldPages=state.editorialPages||[];
  const boxes=[...targets.map(bounds),...oldPages.filter(p=>p.itemIds.every(id=>targetIds.has(id))).map(p=>({x:p.x,y:p.y,w:p.width,h:p.height}))],left=Math.min(...boxes.map(b=>b.x)),top=Math.min(...boxes.map(b=>b.y));
  const input=targets.map(i=>{const p=photoMap.get(i.photoId),g=DoseFilmFrame.metrics(i.width,i.width*p.height/p.width,i.mount,i.sprockets!==false);return {id:i.id,aspect:p.width/p.height,frameInsets:style==='editorial'?{x:0,y:0}:{x:g.mx/g.w,y:g.my/g.h}};});
  if(style==='editorial')state.editorialRevision=((state.editorialRevision||0)%1000000)+1;
  const layout=DoseLayout.layoutPhotos(input,{style,availableWidth:1000,gap:24,origin:{x:left,y:top},variant:Math.max(0,(state.editorialRevision||1)-1)});
  const byId=new Map(layout.items.map(i=>[i.id,i]));for(const item of targets){const next=byId.get(item.id);if(next){item.x=next.x;item.y=next.y;item.width=next.width;item.angle=0;item.group=null;item.layoutSizing='free';item.presentation=style==='editorial'?'print':'film';}}
  const retainedPages=oldPages.map(p=>({...p,itemIds:p.itemIds.filter(id=>!targetIds.has(id))})).filter(p=>p.itemIds.length);
  const others=[...state.items.filter(i=>!targetIds.has(i.id)).map(bounds),...retainedPages.map(p=>({x:p.x,y:p.y,w:p.width,h:p.height}))];
  const placed=[...targets.map(bounds),...layout.pages.map(p=>({x:p.x,y:p.y,w:p.width,h:p.height}))],overlap=(a,b)=>a.x<b.x+b.w&&a.x+a.w>b.x&&a.y<b.y+b.h&&a.y+a.h>b.y;
  let shift=0;
  if(others.length&&placed.some(a=>others.some(b=>overlap(a,b)))){
    shift=Math.max(...others.map(b=>b.x+b.w))+56-Math.min(...placed.map(b=>b.x));for(const item of targets)item.x+=shift;
  }
  const lastNumber=Math.max(0,...retainedPages.map(p=>p.number));state.editorialPages=[...retainedPages,...layout.pages.map(p=>({...p,x:p.x+shift,number:p.number+lastNumber}))];
  selected.clear();librarySelected.clear();fit();changed(true);
}
function reflowSelectedPage(){
  if(busy)return;finishFilmGesture();
  const page=selectedMagazinePage();if(!page)return;
  const byId=new Map(state.items.map(i=>[i.id,i])),members=page.itemIds.map(id=>byId.get(id));
  if(members.some(i=>!i||!photoMap.has(i.photoId)))return;
  const layout=DoseLayout.reflowPage(members.map(i=>{const p=photoMap.get(i.photoId);return {id:i.id,aspect:p.width/p.height};}),page);
  checkpoint();
  for(const next of layout.items)Object.assign(byId.get(next.id),{x:next.x,y:next.y,width:next.width,angle:0,group:null,layoutSizing:'free',presentation:'print'});
  state.editorialPages[state.editorialPages.indexOf(page)]=layout.page;
  changed(true);
}
function layoutMomentsAll(record=true){
  if(!ready||!state.photos.length)return;
  if(record){checkpoint();state.momentsRevision=((state.momentsRevision||0)%1000000)+1;}
  state.layoutStyle='moments';
  const existing=new Map();for(const item of state.items)if(!existing.has(item.photoId))existing.set(item.photoId,item);
  state.items=state.photos.map(p=>existing.get(p.id)||{id:uid(),photoId:p.id,x:0,y:0,width:240,angle:0,mount:state.mount||'bare',sprockets:true,group:null});
  const targets=state.items;
  const input=targets.map(i=>{const p=photoMap.get(i.photoId);return {id:i.id,aspect:p.width/p.height};});
  const layout=DoseLayout.layoutPhotos(input,{style:'moments',availableWidth:1000,gap:24,variant:Math.max(0,(state.momentsRevision||1)-1)}),byId=new Map(layout.items.map(i=>[i.id,i]));
  for(const item of targets){const p=byId.get(item.id);if(p){item.x=p.x;item.y=p.y;item.width=p.width;item.angle=0;item.group=null;item.layoutSizing='free';item.presentation='print';}}
  state.editorialPages=layout.pages;selected.clear();librarySelected.clear();fit();changed(true);
}
function layoutViewportAll(record=true,includeMissing=record){
  if(!ready||!state.photos.length||W<100||H<90)return;
  const previous=state.editorialPages?.find(p=>p.kind==='viewport');
  if(record){checkpoint();state.viewportRevision=((state.viewportRevision||0)%1000000)+1;}state.layoutStyle='viewport';
  if(includeMissing){const placed=new Set(state.items.map(i=>i.photoId));for(const p of state.photos)if(!placed.has(p.id))state.items.push({id:uid(),photoId:p.id,x:0,y:0,width:240,angle:0,mount:state.mount||'bare',sprockets:true,group:null});}
  const order=new Map(state.photos.map((p,k)=>[p.id,k])),targets=state.items.slice().sort((a,b)=>order.get(a.photoId)-order.get(b.photoId));
  const input=targets.map(i=>{const p=photoMap.get(i.photoId),print=record||i.presentation==='print',g=DoseFilmFrame.metrics(i.width,i.width*p.height/p.width,print?'bare':i.mount,!print&&i.sprockets!==false);return {id:i.id,aspect:p.width/p.height,frameInsets:{x:g.mx/g.w,y:g.my/g.h}};});
  const scale=clamp((W-48)/1000,.05,8),worldHeight=(H-96)/scale;
  const result=DoseViewportLayout.layoutViewport(input,{width:1000,height:Math.max(10,worldHeight),variant:Math.max(0,(state.viewportRevision||1)-1),composition:record?'':previous?.composition,avoidComposition:record?previous?.composition:''}),byId=new Map(result.items.map(i=>[i.id,i]));
  for(const item of targets){const p=byId.get(item.id);if(p){item.x=p.x;item.y=p.y;item.width=p.width;item.angle=0;item.group=null;if(record)item.presentation='print';item.layoutSizing='viewport';}}
  state.editorialPages=result.pages;state.camera={zoom:scale,x:24-W/2,y:20-H/2};canvas.dataset.viewportSize=W+'x'+H;canvas.dataset.viewportComposition=result.metrics.composition;
  if(record)selected.clear();librarySelected.clear();changed(true);
}
function sleeve(){if(!state.photos.length)return;checkpoint();let items=state.items.filter(i=>selected.has(i.id));
  if(!items.length){items=state.photos.map(p=>({id:uid(),photoId:p.id,width:220,angle:0,mount:'bare'}));state.items=items;}
  const origin=items[0]?{x:items[0].x||0,y:items[0].y||0}:{x:0,y:0};
  items.forEach((i,k)=>{const p=photoMap.get(i.photoId),page=Math.floor(k/6);if(k%6===0)items._group=uid();i.group=items._group;i.angle=0;i.mount='bare';i.width=Math.min(220,150*p.width/p.height);i.x=origin.x+page*590+(k%2)*255;i.y=origin.y+Math.floor(k%6/2)*225;});selected=new Set(items.map(i=>i.id));fit();changed(true);toast('已装入胶片袋。拖动任一胶片可移动整袋，Alt+拖动可取出单片。');
}
function zoom(factor,p={x:W/2,y:H/2}){const q=world(p),z=clamp(state.camera.zoom*factor,.05,8);state.camera.zoom=z;state.camera.x=p.x-W/2-q.x*z;state.camera.y=p.y-H/2-q.y*z;changed();}
function transformSelected(action){if(!selected.size)return;checkpoint();for(const i of state.items)if(selected.has(i.id)){if(i.group)i.group=null;action(i);}changed();}
function removeSelected(){if(!selected.size)return;checkpoint();state.items=state.items.filter(i=>!selected.has(i.id));selected.clear();librarySelected.clear();changed(true);toast('已移出台面，照片仍保留在胶片库。Ctrl+Z 可撤销。');}
function setTool(next){tool=next;close=false;pointer.inside=false;updateControls();requestDraw();}
function toggleLight(){state.lit=!state.lit;if(state.lit)lampStart=performance.now();changed();}
async function importPhotos(folder=false,files=null){if(busy)return;busy=true;updateControls();toast('正在准备胶片…',60000);
  try{const result=files?await api.drop(files):await api.pick(folder);const count=result.photos.length;
    for(const p of result.photos){if(!photoMap.has(p.id)){state.photos.push(p);photoMap.set(p.id,p);}}
    if(count){await warmPhotos(result.photos);if(state.layoutStyle==='moments')layoutMomentsAll(false);else if(state.layoutStyle==='viewport')layoutViewportAll(true,true);else if(!state.items.length)arrange();else changed(true);}
    if(result.errors.length)toast(`导入 ${count} 张。${result.errors.length} 个文件无法读取：${result.errors.slice(0,3).join('、')}`,10000);
    else if(count)toast(`已导入 ${count} 张照片${result.limit?'（本次最多 5000 张）':''}。原文件保持不变。`);
    else {$('#toast').hidden=true;if(files)toast('没有新增照片。文件可能已经导入，或不是支持的格式。');}
  }catch(e){toast('导入失败：'+e.message,10000);}finally{busy=false;updateControls();}
}
function eventPoint(e){const r=canvas.getBoundingClientRect();return{x:e.clientX-r.left,y:e.clientY-r.top};}
canvas.addEventListener('pointerdown',e=>{
  if(e.button>1)return;canvas.focus();pointer={...eventPoint(e),inside:true};if(tool==='loupe'&&e.button===0){requestDraw();return;}
  librarySelected.clear();
  const p=pointer,q=world(p),item=hit(p);canvas.setPointerCapture(e.pointerId);
  if(e.shiftKey&&!item&&e.button===0){drag={type:'select',start:p,previous:e.ctrlKey?new Set(selected):new Set()};selectionRect={x:p.x,y:p.y,w:0,h:0};}
  else if(item&&e.button===0){
    if(e.ctrlKey){if(selected.has(item.id))selected.delete(item.id);else selected.add(item.id);updateControls();requestDraw();return;}
    checkpoint();if(e.altKey&&item.group)item.group=null;
    if(!selected.has(item.id))selected=new Set(item.group?state.items.filter(i=>i.group===item.group).map(i=>i.id):[item.id]);
    const originals=state.items.filter(i=>selected.has(i.id)).map(i=>({id:i.id,x:i.x,y:i.y}));
    state.items=[...state.items.filter(i=>!selected.has(i.id)),...state.items.filter(i=>selected.has(i.id))];drag={type:'items',start:q,originals};
  }else{if(!e.ctrlKey)selected.clear();librarySelected.clear();drag={type:'pan',start:p,camera:{...state.camera}};}
  updateControls();requestDraw();
});
canvas.addEventListener('pointermove',e=>{
  const p=eventPoint(e);pointer={...p,inside:true};
  if(drag){
    if(drag.type==='pan'){state.camera.x=drag.camera.x+p.x-drag.start.x;state.camera.y=drag.camera.y+p.y-drag.start.y;}
    if(drag.type==='items'){const q=world(p);for(const o of drag.originals){const i=state.items.find(i=>i.id===o.id);i.x=o.x+q.x-drag.start.x;i.y=o.y+q.y-drag.start.y;}}
    if(drag.type==='select'){selectionRect={x:Math.min(p.x,drag.start.x),y:Math.min(p.y,drag.start.y),w:Math.abs(p.x-drag.start.x),h:Math.abs(p.y-drag.start.y)};selected=new Set(drag.previous);for(const i of state.items){const s=screen(i);if(s.x>=selectionRect.x&&s.x<=selectionRect.x+selectionRect.w&&s.y>=selectionRect.y&&s.y<=selectionRect.y+selectionRect.h)selected.add(i.id);}}
    requestDraw();
  }else if(tool==='loupe')requestDraw();
  else canvas.style.cursor=hit(p)?'grab':'default';
});
function endDrag(){if(drag){drag=null;selectionRect=null;changed();}}
canvas.addEventListener('pointerup',endDrag);canvas.addEventListener('pointercancel',endDrag);canvas.addEventListener('lostpointercapture',endDrag);
canvas.addEventListener('pointerleave',()=>{if(!drag){pointer.inside=false;close=false;requestDraw();}});
canvas.addEventListener('dblclick',e=>{const i=hit(eventPoint(e));if(i){librarySelected.clear();selected=new Set([i.id]);setFilmPanel(true);}});
canvas.addEventListener('wheel',e=>{e.preventDefault();if(e.altKey&&selected.size){if(!drag?.wheel){checkpoint();}for(const i of state.items)if(selected.has(i.id)){i.width=clamp(i.width*Math.exp(-e.deltaY*.001),60,2400);i.group=null;}changed();}else zoom(Math.exp(-e.deltaY*.0015),eventPoint(e));},{passive:false});
let dragDepth=0;
document.addEventListener('dragenter',e=>{e.preventDefault();if(e.dataTransfer.types.includes('Files')){dragDepth++;$('#drop-cover').hidden=false;}});
document.addEventListener('dragleave',e=>{if(e.dataTransfer.types.includes('Files')&&--dragDepth<=0){dragDepth=0;$('#drop-cover').hidden=true;}});
document.addEventListener('dragover',e=>{e.preventDefault();e.dataTransfer.dropEffect='copy';});
document.addEventListener('drop',e=>{e.preventDefault();dragDepth=0;$('#drop-cover').hidden=true;const id=e.dataTransfer.getData('application/x-lighttable-photo');if(id&&photoMap.has(id)){const r=stage.getBoundingClientRect();if(e.clientY>=r.top&&e.clientY<r.bottom)place(id,eventPoint(e));}else if(e.dataTransfer.files.length)importPhotos(false,[...e.dataTransfer.files]);});
function mechanical(first=false){if(!state.sound)return;
  try{audioContext??=new AudioContext();audioContext.resume();const ac=audioContext,t=ac.currentTime;
    // Original synthesized spring, latch and transport sounds; no third-party samples.
    for(const [delay,duration,frequency,volume] of (first?[[.03,.055,900,.11],[.12,.09,340,.07]]:[[0,.04,1200,.1],[.07,.12,280,.065],[.2,.035,1700,.08]])){
      const length=Math.ceil(ac.sampleRate*duration),buffer=ac.createBuffer(1,length,ac.sampleRate),data=buffer.getChannelData(0);
      for(let i=0;i<length;i++)data[i]=(Math.random()*2-1)*Math.exp(-i/(length*.22));
      const source=ac.createBufferSource(),filter=ac.createBiquadFilter(),gain=ac.createGain();source.buffer=buffer;filter.type='bandpass';filter.frequency.value=frequency;filter.Q.value=.65;gain.gain.value=volume;source.connect(filter).connect(gain).connect(ac.destination);source.start(t+delay);
      const osc=ac.createOscillator(),og=ac.createGain();osc.type='triangle';osc.frequency.setValueAtTime(frequency*.35,t+delay);osc.frequency.exponentialRampToValueAtTime(70,t+delay+duration);og.gain.setValueAtTime(volume*.18,t+delay);og.gain.exponentialRampToValueAtTime(.0001,t+delay+duration);osc.connect(og).connect(ac.destination);osc.start(t+delay);osc.stop(t+delay+duration);
    }
  }catch{}
}
async function startSlideshow(photoId=null){if(!state.photos.length)return;await flush();projecting=true;close=false;pointer.inside=false;slidePhotos=[...state.photos];shuffled=false;slideIndex=Math.max(0,slidePhotos.findIndex(p=>p.id===photoId));$('#projection').hidden=true;$('#workbench').inert=true;$('.topbar').inert=true;$('#shuffle').textContent='随机顺序 关';$('#shuffle').setAttribute('aria-pressed',false);await api.fullscreen(true);await showSlide(true);if(projecting){$('#projection').hidden=false;$('#exit-projection').focus();}}
async function showSlide(first=false,direction=1){
  const token=++slideToken,p=slidePhotos[slideIndex],im=$('#projected-image');
  const photo=new Image();photo.src=photoURL(p.id,'full',filmOriginal);let failed=false;try{await photo.decode();}catch{failed=true;}
  if(token!==slideToken)return;
  if(failed){toast('这张照片已移动或无法读取，可继续切换下一张。');return;}
  $('#slide-count').textContent=`${pad(slideIndex+1)} / ${pad(slidePhotos.length)}`;$('#slide-name').textContent=p.name;mechanical(first);
  im.getAnimations().forEach(a=>a.cancel());im.src=photo.src;im.alt=p.name;im.style.visibility='visible';
  if(!reduced)im.animate([{transform:`translateX(${direction*70}px) rotate(${-direction*1.5}deg)`,opacity:.1,filter:'blur(2px) brightness(1.3)'},{transform:'translateX(0) rotate(0)',opacity:1,filter:'blur(0) brightness(.98)'}],{duration:260,easing:'cubic-bezier(.18,.7,.2,1)'});
}
function slideBy(delta){if(!projecting)return;slideIndex=(slideIndex+delta+slidePhotos.length)%slidePhotos.length;showSlide(false,delta);}
async function stopSlideshow(){slideToken++;projecting=false;$('#projection').hidden=true;$('#projected-image').getAnimations().forEach(a=>a.cancel());$('#workbench').inert=false;$('.topbar').inert=false;await api.fullscreen(false);canvas.focus();resize();requestDraw();}
$('#previous').onclick=()=>slideBy(-1);$('#next').onclick=()=>slideBy(1);$('#exit-projection').onclick=stopSlideshow;$('#slideshow').onclick=()=>startSlideshow();
$('#shuffle').onclick=()=>{const current=slidePhotos[slideIndex];shuffled=!shuffled;slidePhotos=[...state.photos];if(shuffled)for(let k=slidePhotos.length-1;k>0;k--){const j=Math.floor(Math.random()*(k+1));[slidePhotos[k],slidePhotos[j]]=[slidePhotos[j],slidePhotos[k]];}slideIndex=slidePhotos.findIndex(p=>p.id===current.id);$('#shuffle').textContent=shuffled?'随机顺序 开':'随机顺序 关';$('#shuffle').setAttribute('aria-pressed',shuffled);$('#slide-count').textContent=`${pad(slideIndex+1)} / ${pad(slidePhotos.length)}`;};
$('#sound').onclick=()=>{state.sound=!state.sound;changed();};
$('#import').onclick=()=>importPhotos();$('#empty-import').onclick=()=>importPhotos();$('#import-folder').onclick=()=>importPhotos(true);
$('#arrange').onclick=arrange;$('#sleeve').onclick=sleeve;$('#fit').onclick=()=>photoView.open?photoView.fit():fit();$('#zoom-out').onclick=()=>photoView.open?photoView.scale(1/1.2):zoom(1/1.2);$('#zoom-in').onclick=()=>photoView.open?photoView.scale(1.2):zoom(1.2);$('#pointer').onclick=()=>setTool('pointer');$('#loupe').onclick=()=>setTool(tool==='loupe'?'pointer':'loupe');$('#power').onclick=toggleLight;
$('#auto-layout').onclick=()=>autoLayout();$('#layout-style').onchange=e=>autoLayout(e.target.value);
$('#reflow-page').onclick=reflowSelectedPage;
$('#share-grid').onclick=()=>{finishFilmGesture();shareComposer.show(state.items.find(i=>selected.has(i.id))?.id);};
$('#sprockets').onclick=()=>{const items=state.items.filter(i=>selected.has(i.id));if(!items.length)return;const enabled=!items.every(i=>geometry(i).film);transformSelected(i=>{i.sprockets=enabled;i.presentation='film';if(enabled)i.mount='bare';});if(state.layoutStyle==='viewport')layoutViewportAll(false);};
$('#magnification').onclick=()=>{state.closeMode=state.closeMode==='8'?'original':'8';changed();};
$('#brightness').oninput=e=>{state.brightness=Number(e.target.value)/100;changed();};
$('#rotate-left').onclick=()=>transformSelected(i=>i.angle-=5);$('#rotate-right').onclick=()=>transformSelected(i=>i.angle+=5);$('#scale-down').onclick=()=>transformSelected(i=>i.width=clamp(i.width/1.15,i.layoutSizing==='viewport'||i.presentation==='print'?.001:60,2400));$('#scale-up').onclick=()=>transformSelected(i=>i.width=clamp(i.width*1.15,i.layoutSizing==='viewport'||i.presentation==='print'?.001:60,2400));$('#remove').onclick=removeSelected;
$('#mount').onclick=()=>{const bare=state.items.filter(i=>selected.has(i.id)).every(i=>i.presentation!=='print'&&i.mount==='slide');transformSelected(i=>{i.presentation='film';i.mount=bare?'bare':'slide';});if(state.layoutStyle==='viewport')layoutViewportAll(false);};
function setFilmPanel(open){$('#film-panel').hidden=!open;$('#film-color').setAttribute('aria-expanded',String(open));if(open){setPhotoView(true);updateFilmPanel();for(const id of previewTargets(filmTargets())){const a=adjustmentOf(id);livePreview.prepare(id,photoURL(id,'800',true),a.lut?(a.lutId||filmStatus.hash):'').catch(()=>{});}}else{finishFilmGesture();photoView.hide();updateControls();$('#film-color').focus();}}
$('#film-color').onclick=()=>setFilmPanel($('#film-panel').hidden);$('#film-panel-close').onclick=()=>setFilmPanel(false);
$('#focus-photo').onclick=()=>setPhotoView(!photoView.open);
$('#browse-luts').onclick=()=>{finishFilmGesture();lutBrowser.show();};
$('#library-search').oninput=e=>{if(e.isComposing)return;clearTimeout(librarySearchTimer);librarySearchTimer=setTimeout(applyLibraryFilter,180);};
$('#library-search').oncompositionend=applyLibraryFilter;
$('#library-search-clear').onclick=()=>{$('#library-search').value='';applyLibraryFilter();$('#library-search').focus();};
$('#library-filter').onchange=applyLibraryFilter;
$('#library-sort').onchange=()=>{applyLibraryFilter();savePreferences({librarySort:$('#library-sort').value});};
$('#library-reset').onclick=()=>{$('#library-search').value='';$('#library-filter').value='all';applyLibraryFilter();};
function chooseLut(value){
  const ids=filmTargets();if(!ids.length||value.startsWith('__'))return;
  finishFilmGesture();checkpoint();
  for(const id of ids){const p=photoMap.get(id);if(p)p.adjustments=globalThis.LightTableFilm.withLut(adjustmentOf(id),value);}
  queueLive(ids);changed(true);
}
$('#lut-library').onchange=e=>chooseLut(e.target.value);
$('#lut-strength').oninput=e=>{liveInput('strength',Number(e.target.value));$('#lut-strength-value').textContent=e.target.value+'%';};
$('#lut-strength').onchange=e=>{liveInput('strength',Number(e.target.value));finishFilmGesture();};
$('#lut-strength').onpointercancel=finishFilmGesture;
$('#film-reset').onclick=()=>{const ids=filmTargets();if(!ids.length)return;checkpoint();for(const id of ids)photoMap.get(id).adjustments={...DEFAULT_ADJUSTMENTS};changed(true);toast('已还原');};
function setFilmOriginal(on){filmOriginal=on;$('#film-original').setAttribute('aria-pressed',String(on));refreshFilmImages();}$('#film-original').onpointerdown=()=>setFilmOriginal(true);['pointerup','pointercancel','pointerleave'].forEach(ev=>$('#film-original').addEventListener(ev,()=>setFilmOriginal(false)));$('#film-original').onkeydown=e=>{if(e.key===' '||e.key==='Enter'){e.preventDefault();setFilmOriginal(true);}};$('#film-original').onkeyup=e=>{if(e.key===' '||e.key==='Enter')setFilmOriginal(false);
};
$('#import-lut').onclick=async()=>{if(!api.importLut)return;try{const result=await api.importLut();if(result){filmStatus={...filmStatus,...result};if(filmTargets().length)chooseLut(result.hash);else updateFilmPanel();toast('LUT 已导入');}}catch(e){toast('导入 LUT 失败：'+e.message);}};
$('#help').onclick=()=>$('#help-dialog').showModal();$('#help-done').onclick=()=>$('#help-dialog').close();$('.dialog-close').onclick=()=>$('#help-dialog').close();
$('#export-layout').onclick=async()=>{try{if(await api.export(state))toast('布局已导出。布局仅保存照片路径，请保留原照片。');}catch(e){toast('导出失败：'+e.message);}};
$('#export-photos').onclick=async()=>{const button=$('#export-photos');if(button.disabled)return;photoExporting=true;updateFilmPanel();button.textContent='导出中…';try{await flush();const ids=filmTargets();const modern=ids.length>0&&ids.every(tiffCapable);const choice=$('#export-format')?.value;const format=choice==='tiff'&&modern?'tiff':choice==='png'?'png':'jpeg';const result=await api.exportPhotos?.(ids,format);if(result?.canceled)toast('已取消导出。');else{toast(`已导出 ${result?.count||0} 张照片${result?.failed?`，${result.failed} 张失败`:''}。`);const open=$('#open-export-folder');if(open&&result?.folder){open.hidden=false;open.dataset.folder=result.folder;}}}catch(e){toast('照片导出失败：'+(e?.message||'未知错误'));}finally{photoExporting=false;button.textContent='导出照片';updateFilmPanel();}};
$('#open-export-folder').onclick=async()=>{try{await api.openExportFolder?.($('#open-export-folder').dataset.folder);}catch(e){toast('无法打开导出文件夹：'+(e?.message||'未知错误'));}};
$('#open-layout').onclick=async()=>{try{await flush();const next=await api.open();if(next){state=normalize(next);history=[];future=[];selected.clear();librarySelected.clear();rebuild();changed(true);toast('已打开布局。');}}catch(e){toast('无法打开布局：'+e.message);}};
$('#new-layout').onclick=async()=>{if(busy)return;try{await flush();const next=await api.newTable();if(next){state=normalize(next);history=[];future=[];selected.clear();librarySelected.clear();images.clear();rebuild();changed(true);toast('已新建台面。旧布局已备份在本机 backups 文件夹。');}}catch(e){toast('新建失败：'+e.message);}};
window.addEventListener('keydown',e=>{
  if(shareComposer.open||lutBrowser.open)return;
  if(!ready||$('#help-dialog').open)return;
  if(projecting){if(e.key==='Escape'){e.preventDefault();stopSlideshow();}else if(['ArrowRight','ArrowDown','PageDown',' '].includes(e.key)){e.preventDefault();slideBy(1);}else if(['ArrowLeft','ArrowUp','PageUp'].includes(e.key)){e.preventDefault();slideBy(-1);}return;}
  if(e.ctrlKey&&['f','k'].includes(e.key.toLowerCase())){e.preventDefault();$('#library-search').focus();$('#library-search').select();return;}
  if(e.key==='Escape'&&document.activeElement===$('#library-search')&&$('#library-search').value){e.preventDefault();$('#library-search').value='';applyLibraryFilter();return;}
  if(e.key==='Escape'&&!$('#film-panel').hidden){e.preventDefault();setFilmPanel(false);return;}
  const k=e.key.toLowerCase(),input=['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName);
  if(e.ctrlKey&&k==='o'){e.preventDefault();importPhotos(!e.shiftKey);return;}if(e.ctrlKey&&k==='l'){e.preventDefault();toggleLight();return;}
  if(e.ctrlKey&&k==='z'&&(!input||document.activeElement.matches('select,input[type="range"]'))){e.preventDefault();finishFilmGesture();undo(e.shiftKey);return;}if(input)return;
  if(e.ctrlKey&&k==='a'){e.preventDefault();if(librarySelected.size||document.activeElement.closest('.film-thumb')){librarySelected=new Set(visibleLibraryPhotos().map(p=>p.id));selected=new Set(state.items.filter(i=>librarySelected.has(i.photoId)).map(i=>i.id));}else selected=new Set(state.items.map(i=>i.id));updateControls();requestDraw();return;}
  if(k==='e'){e.preventDefault();if(photoView.open)setPhotoView(false);else setFilmPanel(true);return;}
  if(photoView.open){if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();navigatePhoto(e.key==='ArrowLeft'?-1:1);return;}if(k==='f'){photoView.fit();return;}if(k===' '&&document.activeElement===canvas){e.preventDefault();setFilmOriginal(true);return;}if(k==='+'||k==='='){photoView.scale(1.25);return;}if(k==='-'){photoView.scale(.8);return;}}
  if(k==='a'&&!photoView.open)setTool('pointer');else if(k==='v'&&!photoView.open)setTool('loupe');else if(k==='f')fit();else if(k==='z'&&e.shiftKey)arrange();else if(k==='delete'||k==='backspace'){e.preventDefault();removeSelected();}
  else if(k==='[')transformSelected(i=>i.angle-=5);else if(k===']')transformSelected(i=>i.angle+=5);else if(k==='escape'){selected.clear();librarySelected.clear();close=false;changed();}
  else if(k===' '&&tool==='loupe'){e.preventDefault();close=true;requestDraw();}else if(k==='tab'&&tool==='loupe'){e.preventDefault();$('#magnification').click();}
});
window.addEventListener('keyup',e=>{if(e.key===' '){close=false;if(photoView.open)setFilmOriginal(false);requestDraw();}});
window.addEventListener('blur',()=>{finishFilmGesture();close=false;pointer.inside=false;setFilmOriginal(false);endDrag();requestDraw();});
$('#reference-editor').onclick=async()=>{const ids=filmTargets();if(!ids.length)return;try{await flush();await api.openReferenceEditor(ids);}catch(e){toast('无法打开显影室：'+e.message,12000);}};
api.onReferenceResult?.(async({photo,sourceIds=[]})=>{
  if(!ready||!photo)return;finishFilmGesture();checkpoint();
  if(!state.photos.some(p=>p.id===photo.id))state.photos.push({...photo,adjustments:{...DEFAULT_ADJUSTMENTS}});
  const ids=new Set(sourceIds);let replaced=false;
  for(const item of state.items)if(ids.has(item.photoId)){item.photoId=photo.id;replaced=true;}
  if([...librarySelected].some(id=>ids.has(id))){for(const id of ids)librarySelected.delete(id);librarySelected.add(photo.id);}
  rebuild();if(replaced)changed(true);else place(photo.id,null,false);await flush();
  toast('显影完成');
});
api.onProgress(p=>{$('#toast span').textContent=`正在准备胶片 ${p.done} / ${p.total}…`;});api.onClose(flush);
function normalize(s){const out={version:1,photos:[],items:[],editorialPages:[],editorialRevision:0,momentsRevision:0,viewportRevision:0,camera:{x:0,y:0,zoom:1},brightness:1,lit:true,transmission:true,sound:true,mount:'bare',closeMode:'original',...s};out.photos=out.photos.map(p=>{const raw=p.adjustments||{},legacy=raw.engine==='spectral'&&raw.spectralVersion==null;return {...p,adjustments:{...DEFAULT_ADJUSTMENTS,...raw,...(legacy?{spectralVersion:1,spectralPaper:raw.spectralPaper||'kodak_portra_endura'}:{})}}});return out;}
function rebuild(){photoMap.clear();for(const p of state.photos)photoMap.set(p.id,p);lamp=state.lit?1:0;}
initFilmPanel();
for(const [field] of filmFields){const input=$(`#film-${field}`);input.title='双击还原此项';input.addEventListener('dblclick',()=>{if(input.disabled)return;clearTimeout(filmDebounce);filmGesture=null;checkpoint();applyFilmField(field,0);});}
try {
  const loaded=await api.load();state=normalize(loaded.state);$('.help-note strong').textContent='dose for Windows · '+loaded.version;rebuild();
  if(api.filmStatus)filmStatus=await api.filmStatus()||filmStatus;
  try{uiPreferences=await api.preferences();$('#library-sort').value=uiPreferences.librarySort;}catch{toast('本机偏好暂时无法读取。');}
  for(const p of state.photos)if(p.adjustments?.lut&&!p.adjustments.lutId)p.adjustments.lutId=filmStatus.hash||'';
  await warmPhotos(state.photos);ready=true;document.body.dataset.ready='true';resize();renderLibrary();updateControls();requestDraw();
  if(loaded.warning)toast(loaded.warning,10000);
}catch(e){toast('启动失败：'+e.message,60000);}

