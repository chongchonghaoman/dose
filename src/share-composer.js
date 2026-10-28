const G=globalThis.DoseShareGrid,L=globalThis.DoseShareLayout;
const $=id=>document.getElementById(id),EDGE=2400,SETTINGS='dose-share-square-v1';
const styles=['editorial','moments','viewport','grid','contact'];
function signature(photos){const text=JSON.stringify(photos.map(p=>[p.id,p.width,p.height]));let h=2166136261;for(let n=0;n<text.length;n++){h^=text.charCodeAt(n);h=Math.imul(h,16777619);}return photos.length+':'+(h>>>0).toString(16);}
export class ShareComposer {
  constructor({api,getScene,getSource,getFallback,notify}){
    Object.assign(this,{api,getScene,getSource,getFallback,notify});this.dialog=$('share-dialog');this.canvas=$('share-canvas');this.busy=false;this.session=null;this.cache=new Map();this.pending=new Map();this.queue=new Map();this.active=new Set();this.failed=new Set();this.sequence=0;this.cachePixels=0;
    new ResizeObserver(()=>this.resize()).observe($('share-view'));
    this.dialog.addEventListener('cancel',e=>{e.preventDefault();this.close();});$('share-close').onclick=()=>this.close();
    for(const id of ['share-mag','share-lens','share-background','share-guides'])$(id).oninput=()=>this.controls(id);
    $('share-layout').onchange=()=>this.reflow($('share-layout').value,this.session?.variant||0);
    $('share-reflow').onclick=()=>this.reflow(this.session?.style,(this.session?.variant||0)+1);
    $('share-focus').onchange=()=>this.focus($('share-focus').value);$('share-center').onclick=()=>this.focus(this.session?.crop.focusId);
    $('share-export').onclick=()=>this.export();$('share-open-folder').onclick=()=>this.api.openExportFolder();
    this.canvas.addEventListener('pointerdown',e=>this.startDrag(e));this.canvas.addEventListener('pointermove',e=>this.movePointer(e));
    this.canvas.addEventListener('pointerup',()=>this.endDrag());this.canvas.addEventListener('lostpointercapture',()=>this.endDrag());this.canvas.addEventListener('pointercancel',()=>this.endDrag());
    this.canvas.addEventListener('wheel',e=>{e.preventDefault();if(!this.session||this.busy)return;this.changeLens({mag:this.session.crop.mag*Math.exp(-e.deltaY*.001)});},{passive:false});
    this.canvas.addEventListener('keydown',e=>{
      if(!this.session||this.busy)return;const c=this.session.crop,step=EDGE*(e.shiftKey?.05:.01),delta={ArrowLeft:[-step,0],ArrowRight:[step,0],ArrowUp:[0,-step],ArrowDown:[0,step]}[e.key];
      if(delta){e.preventDefault();this.changeLens({lensX:c.lensX+delta[0],lensY:c.lensY+delta[1]},true);}
      else if(['+','=','-','[',']'].includes(e.key)){e.preventDefault();this.changeLens(e.key==='['?{lens:c.lens-.01}:e.key===']'?{lens:c.lens+.01}:{mag:c.mag*(e.key==='-'?1/1.1:1.1)});}
    });
    window.addEventListener('beforeunload',()=>this.persist());
  }
  get open(){return this.dialog.open;}
  remembered(){if(this.last)return this.last;try{return JSON.parse(localStorage.getItem(SETTINGS)||'null');}catch{return null;}}
  async show(preferred){
    if(this.open||this.opening)return;this.opening=true;
    try{
    const source=this.getScene();if(!source.photos.length){this.notify('先添加照片，再进入朋友圈分割。');return;}
    const total=source.photos.length,availability=await this.api.photoAvailability(source.photos.map(p=>p.id)),available=new Set(availability.available);
    source.photos=source.photos.filter(p=>available.has(p.id));source.items=source.items.filter(i=>available.has(i.photoId));
    if(!source.photos.length){this.notify('原片均不可用，请重新导入照片后再排版。');return;}
    const sig=signature(source.photos),last=this.remembered(),same=last?.signature===sig,preferredPhotoId=source.items.find(i=>i.id===preferred)?.photoId||(same&&source.photos.some(p=>p.id===last.preferredPhotoId)?last.preferredPhotoId:source.photos[0].id);
    const style=same&&styles.includes(last.style)?last.style:styles.includes(source.layoutStyle)?source.layoutStyle:'editorial',variant=same&&Number.isFinite(last.variant)?Math.max(0,Math.min(1000000,Math.floor(last.variant))):0;
    let layout;try{layout=L.layoutSquare(source.photos,{style,variant,edge:EDGE});}catch(e){this.notify('暂时无法编排这些照片：'+e.message);return;}
    const scene={photos:source.photos,items:layout.items},photos=new Map(source.photos.map(p=>[p.id,p])),initialItem=layout.items.find(i=>i.photoId===preferredPhotoId)||layout.items[0];
    let crop=G.initial(initialItem,photos.get(initialItem.photoId),EDGE);
    if(same&&last.crop){crop=G.constrain({...last.crop,size:EDGE},initialItem);if(!scene.items.some(i=>i.id===crop.focusId))crop.focusId=initialItem.id;if(last.preferredPhotoId!==preferredPhotoId)crop=G.constrain({...crop,focusId:initialItem.id,lensX:initialItem.x,lensY:initialItem.y},initialItem);}
    this.sequence++;this.dialog.dataset.generation=String(this.sequence);this.session={scene,photos,crop,layout,style,variant,signature:sig,preferredPhotoId,total,unavailable:total-source.photos.length};this.abort=new AbortController();
    $('share-focus').replaceChildren(...scene.items.map(i=>{const o=document.createElement('option');o.value=i.id;o.textContent=photos.get(i.photoId)?.name||'照片';return o;}));
    $('share-open-folder').hidden=true;$('share-status').hidden=true;$('share-guides').checked=same?last.guides!==false:true;this.publishLayout();this.sync();this.dialog.showModal();requestAnimationFrame(()=>{this.resize();this.canvas.focus();});
    }catch(e){this.notify('暂时无法检查原片：'+e.message);}finally{this.opening=false;}
  }
  persist(){if(!this.session)return;const s=this.session;this.last={signature:s.signature,preferredPhotoId:s.preferredPhotoId,style:s.style,variant:s.variant,crop:{...s.crop},guides:$('share-guides').checked};try{localStorage.setItem(SETTINGS,JSON.stringify(this.last));}catch{}}
  close(){
    if(this.busy)return;this.persist();this.endDrag();this.sequence++;this.abort?.abort();for(const entry of this.cache.values())entry.image.close();this.cache.clear();this.cachePixels=0;this.pending.clear();this.queue.clear();this.active.clear();this.failed.clear();this.session=null;this.dialog.close();$('share-grid').focus();
  }
  focusItem(){return this.session?.scene.items.find(i=>i.id===this.session.crop.focusId);}
  focus(id){if(!this.session||this.busy)return;const item=this.session.scene.items.find(i=>i.id===id);if(!item)return;this.changeLens({focusId:id,lensX:item.x,lensY:item.y});}
  reflow(style,variant){
    if(!this.session||this.busy)return;const s=this.session;
    try{const layout=L.layoutSquare(s.scene.photos,{style,variant:variant%1000000,edge:EDGE});s.layout=layout;s.scene.items=layout.items;s.style=layout.style;s.variant=layout.variant;s.crop=G.constrain({...s.crop,size:EDGE},this.focusItem());this.publishLayout();this.sync();this.requestRender();}
    catch(e){$('share-layout').value=s.style;this.message('这组照片暂时无法排版：'+e.message);}
  }
  publishLayout(){const s=this.session;this.canvas.dataset.layout=JSON.stringify(s.layout);}
  sync(){
    const s=this.session,c=s.crop;$('share-layout').value=s.style;$('share-focus').value=c.focusId;$('share-mag').value=String(c.mag);$('share-lens').value=String(c.lens*100);$('share-background').value=c.background;
    $('share-mag-value').textContent=c.mag.toFixed(1)+'×';$('share-lens-value').textContent=Math.round(c.lens*200)+'%';$('share-count').textContent=s.scene.items.length+(s.unavailable?' 张可用':' 张');$('share-missing').hidden=!s.unavailable;$('share-missing').textContent=s.unavailable+' 张原片不可用';
  }
  controls(id){if(!this.session||this.busy)return;if(id==='share-guides'){this.requestRender();return;}this.changeLens(id==='share-mag'?{mag:Number($('share-mag').value)}:id==='share-lens'?{lens:Number($('share-lens').value)/100}:{background:$('share-background').value});}
  point(e){const b=this.canvas.getBoundingClientRect();return {x:(e.clientX-b.x)/b.width*EDGE,y:(e.clientY-b.y)/b.height*EDGE};}
  changeLens(patch,detect=false){
    if(!this.session||this.busy)return;const s=this.session;s.crop=G.constrain({...s.crop,...patch,size:EDGE},this.focusItem());
    if(detect){const item=G.hit(s.scene.items,s.photos,{x:s.crop.lensX,y:s.crop.lensY});if(item)s.crop.focusId=item.id;}
    this.sync();this.requestRender();
  }
  startDrag(e){
    if(this.busy||!this.session||e.button!==0)return;e.preventDefault();this.canvas.focus();const p=this.point(e),c=this.session.crop,distance=Math.hypot(p.x-c.lensX,p.y-c.lensY),radius=c.size*c.lens,ring=Math.max(10*EDGE/this.side,radius*.045);
    const type=Math.abs(distance-radius)<=ring?'resize':'move';
    if(type==='move'&&distance>radius)this.changeLens({lensX:p.x,lensY:p.y},true);
    this.drag={type,start:p,crop:{...this.session.crop}};this.canvas.setPointerCapture(e.pointerId);this.canvas.style.cursor=type==='resize'?'nwse-resize':'grabbing';
  }
  movePointer(e){
    if(!this.session||this.busy)return;const p=this.point(e),c=this.session.crop;
    if(this.drag){const d=this.drag;if(d.type==='resize')this.changeLens({lens:Math.hypot(p.x-d.crop.lensX,p.y-d.crop.lensY)/EDGE});else this.changeLens({lensX:d.crop.lensX+p.x-d.start.x,lensY:d.crop.lensY+p.y-d.start.y},true);return;}
    const radius=c.size*c.lens,distance=Math.hypot(p.x-c.lensX,p.y-c.lensY);this.canvas.style.cursor=Math.abs(distance-radius)<=Math.max(10*EDGE/this.side,radius*.045)?'nwse-resize':'grab';
  }
  endDrag(){this.drag=null;if(this.canvas)this.canvas.style.cursor='grab';}
  resize(){if(!this.open||!this.session)return;const view=$('share-view'),side=Math.max(100,Math.min(view.clientWidth-24,view.clientHeight-24)),dpr=Math.min(2,devicePixelRatio||1);this.side=side;this.canvas.style.width=side+'px';this.canvas.style.height=side+'px';this.canvas.width=Math.round(side*dpr);this.canvas.height=Math.round(side*dpr);this.dpr=dpr;this.requestRender();}
  requestRender(){if(this.renderQueued)return;this.renderQueued=true;requestAnimationFrame(()=>{this.renderQueued=false;this.render();});}
  preview(photo,size,urgent=false){
    size=Math.min(size,3200);const cached=this.cache.get(photo.id);if(cached){this.cache.delete(photo.id);this.cache.set(photo.id,cached);}
    const key=photo.id+':'+size;
    if((!cached||cached.size<size)&&!this.failed.has(key)){
      if(!this.pending.has(key)){const job={photo,size,key,seq:this.sequence,signal:this.abort.signal};this.pending.set(key,job);if(urgent)this.queue=new Map([[key,job],...this.queue]);else this.queue.set(key,job);}
      else if(urgent&&this.queue.has(key)){const job=this.queue.get(key);this.queue.delete(key);this.queue=new Map([[key,job],...this.queue]);}
      this.pump();
    }
    return cached?.image||this.getFallback?.(photo)||null;
  }
  pump(){
    while(this.active.size<4&&this.queue.size&&this.session){
      const [key,job]=this.queue.entries().next().value;this.queue.delete(key);this.active.add(job);
      fetch(this.getSource(job.photo,job.size),{signal:job.signal}).then(r=>{if(!r.ok)throw Error(job.photo.name);return r.blob();}).then(createImageBitmap).then(image=>{
        if(job.seq!==this.sequence){image.close();return;}const old=this.cache.get(job.photo.id);if(old&&old.size>=job.size){image.close();return;}if(old){this.cachePixels-=old.image.width*old.image.height;old.image.close();this.cache.delete(job.photo.id);}
        this.cache.set(job.photo.id,{image,size:job.size});this.cachePixels+=image.width*image.height;
        while(this.cachePixels>32000000&&this.cache.size>1){const [id,v]=this.cache.entries().next().value;this.cachePixels-=v.image.width*v.image.height;v.image.close();this.cache.delete(id);}this.requestRender();
      }).catch(e=>{if(job.seq===this.sequence&&e.name!=='AbortError'){this.failed.add(key);console.warn('Share preview:',job.photo.name);}}).finally(()=>{this.active.delete(job);if(job.seq===this.sequence){this.pending.delete(key);this.pump();this.requestRender();}});
    }
  }
  paintPhotos(ctx,view,scale,urgent=false){
    const s=this.session;for(const item of s.scene.items){const p=s.photos.get(item.photoId);if(!p||!G.intersects(G.imageBounds(item,p),view))continue;const image=this.preview(p,G.imageSize(item,p,scale),urgent);if(image)G.paintPhoto(ctx,item,p,image);}
  }
  render(){
    if(!this.session||!this.side||!this.open)return;const s=this.session,c=s.crop,p=G.plan(c,null,this.side),ctx=this.canvas.getContext('2d',{colorSpace:'srgb'});
    ctx.setTransform(this.dpr,0,0,this.dpr,0,0);ctx.fillStyle=G.background(c);ctx.fillRect(0,0,this.side,this.side);ctx.save();ctx.scale(p.scale,p.scale);ctx.translate(-p.view.x,-p.view.y);this.paintPhotos(ctx,p.view,p.scale*this.dpr);ctx.restore();
    G.paintLens(ctx,p,()=>{ctx.fillStyle=G.background(c);ctx.fillRect(p.cx-p.r,p.cy-p.r,p.r*2,p.r*2);ctx.save();ctx.translate(p.cx,p.cy);ctx.scale(p.scale*c.mag,p.scale*c.mag);ctx.translate(-p.sampleX,-p.sampleY);this.paintPhotos(ctx,p.lensView,p.scale*c.mag*this.dpr,true);ctx.restore();});
    if($('share-guides').checked){ctx.strokeStyle=c.background==='dark'?'#ffffffb0':'#26292599';ctx.lineWidth=1;ctx.setLineDash([5,5]);ctx.beginPath();for(let k=1;k<3;k++){ctx.moveTo(this.side*k/3,0);ctx.lineTo(this.side*k/3,this.side);ctx.moveTo(0,this.side*k/3);ctx.lineTo(this.side,this.side*k/3);}ctx.stroke();ctx.setLineDash([]);}
    Object.assign(this.canvas.dataset,{generation:String(this.sequence),edge:String(EDGE),focusId:c.focusId,centerX:String(c.x),centerY:String(c.y),size:String(c.size),lensX:String(c.lensX),lensY:String(c.lensY),lensRadius:String(c.lens),mag:String(c.mag),style:s.style,variant:String(s.variant),itemCount:String(s.scene.items.length),pending:String(this.pending.size),cached:String(this.cache.size)});
  }
  setBusy(value){this.busy=value;for(const el of this.dialog.querySelectorAll('button,input,select'))el.disabled=value;$('share-export').textContent=value?'正在导出…':'导出九张';}
  async compose(){
    const s=this.session,c={...s.crop},edge=4320,p=G.plan(c,null,edge),frame=document.createElement('canvas'),lens=document.createElement('canvas');frame.width=frame.height=edge;lens.width=lens.height=Math.ceil(p.r*2);
    const ctx=frame.getContext('2d',{colorSpace:'srgb'}),lc=lens.getContext('2d',{colorSpace:'srgb'});ctx.fillStyle=lc.fillStyle=G.background(c);ctx.fillRect(0,0,edge,edge);lc.fillRect(0,0,lens.width,lens.height);
    // Preview and export share the same square layout and lens sampling point.
    // Stream one decoded source at a time instead of retaining full originals.
    for(const item of s.scene.items){
      const photo=s.photos.get(item.photoId),b=photo&&G.imageBounds(item,photo);if(!b||!G.intersects(b,p.view))continue;const inLens=G.intersects(b,p.lensView),size=G.imageSize(item,photo,p.scale*(inLens?c.mag:1));
      const response=await fetch(this.getSource(photo,size),{signal:this.abort.signal});if(!response.ok)throw Error('无法读取照片：'+photo.name);const image=await createImageBitmap(await response.blob());
      try{ctx.save();ctx.setTransform(p.scale,0,0,p.scale,-p.view.x*p.scale,-p.view.y*p.scale);G.paintPhoto(ctx,item,photo,image);ctx.restore();if(inLens){lc.save();lc.setTransform(p.scale*c.mag,0,0,p.scale*c.mag,p.r-p.sampleX*p.scale*c.mag,p.r-p.sampleY*p.scale*c.mag);G.paintPhoto(lc,item,photo,image);lc.restore();}}finally{image.close();}
    }
    G.paintLens(ctx,p,()=>ctx.drawImage(lens,p.cx-p.r,p.cy-p.r,p.r*2,p.r*2));lens.width=lens.height=1;
    const blob=await new Promise(resolve=>frame.toBlob(resolve,'image/png'));frame.width=frame.height=1;if(!blob)throw Error('无法生成九宫格画面');return new Uint8Array(await blob.arrayBuffer());
  }
  message(text){$('share-status').hidden=false;$('share-status').textContent=text;}
  async export(){
    if(this.busy||!this.session)return;this.setBusy(true);$('share-open-folder').hidden=true;$('share-status').hidden=true;
    try{const output=await this.api.chooseGridOutput();if(!output)return;const image=await this.compose(),result=await this.api.exportGrid({token:output.token,image});if(result?.count!==9)throw Error('九宫格导出未完成');$('share-open-folder').hidden=false;this.message('已导出九张图片，按 01–09 顺序发布。');}
    catch(e){this.message(e.message||'九宫格导出失败');console.error('Grid export:',e);}finally{this.setBusy(false);}
  }
}
