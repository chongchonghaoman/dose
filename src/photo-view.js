export class PhotoView {
  constructor({canvas,redraw,onZoom,onClose,onNavigate}){
    this.canvas=canvas;this.redraw=redraw;this.onZoom=onZoom;this.id=null;this.zoom=1;this.pan={x:0,y:0};this.drag=null;
    this.chrome=document.querySelector('#photo-view-controls');
    document.querySelector('#photo-back').onclick=onClose;
    document.querySelector('#photo-previous').onclick=()=>onNavigate(-1);
    document.querySelector('#photo-next').onclick=()=>onNavigate(1);
    document.querySelector('#photo-fit').onclick=()=>this.fit();
    canvas.addEventListener('pointerdown',e=>{if(!this.id)return;e.stopImmediatePropagation();if(e.button!==0)return;canvas.focus();canvas.setPointerCapture(e.pointerId);this.drag={x:e.clientX,y:e.clientY,pan:{...this.pan}};});
    canvas.addEventListener('pointermove',e=>{if(!this.id)return;e.stopImmediatePropagation();if(this.drag){this.pan={x:this.drag.pan.x+e.clientX-this.drag.x,y:this.drag.pan.y+e.clientY-this.drag.y};this.redraw();}});
    for(const name of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,e=>{if(!this.id)return;e.stopImmediatePropagation();this.drag=null;});
    canvas.addEventListener('dblclick',e=>{if(!this.id)return;e.stopImmediatePropagation();this.zoom=this.zoom>1?1:2;this.pan={x:0,y:0};this.changed();});
    canvas.addEventListener('wheel',e=>{if(!this.id)return;e.preventDefault();e.stopImmediatePropagation();this.scale(Math.exp(-e.deltaY*.002));},{passive:false});
  }
  get open(){return !!this.id;}
  show(id){if(this.id!==id){this.id=id;this.zoom=1;this.pan={x:0,y:0};}this.chrome.hidden=false;this.canvas.setAttribute('aria-label','单张照片。滚轮缩放、拖动平移，左右方向键切换照片。');this.redraw();}
  hide(){this.id=null;this.drag=null;this.chrome.hidden=true;this.canvas.dataset.view='table';delete this.canvas.dataset.photoId;this.canvas.setAttribute('aria-label','胶片台面');this.redraw();}
  fit(){this.zoom=1;this.pan={x:0,y:0};this.changed();}
  scale(factor){this.zoom=Math.max(1,Math.min(8,this.zoom*factor));this.changed();}
  changed(){this.onZoom();this.redraw();}
  update(photo,photos,original=false){
    document.querySelector('#photo-name').textContent=photo?.name||'';
    const index=photos.findIndex(p=>p.id===this.id);
    document.querySelector('#photo-previous').disabled=index<=0;
    document.querySelector('#photo-next').disabled=!photos.length||index===photos.length-1;
    document.querySelector('#photo-original').hidden=!original;
  }
  paint(ctx,w,h,dpr,entry){
    ctx.setTransform(dpr,0,0,dpr,0,0);ctx.fillStyle='#121412';ctx.fillRect(0,0,w,h);
    this.canvas.dataset.view='photo';this.canvas.dataset.photoId=this.id;this.canvas.dataset.photoZoom=String(this.zoom);
    this.canvas.style.cursor=this.zoom>1?'grab':'default';
    const image=entry?.image;
    if(image){
      const iw=image.naturalWidth||image.width,ih=image.naturalHeight||image.height;
      const aw=Math.max(1,w-48),ah=Math.max(1,h-112),fit=Math.min(aw/iw,ah/ih),dw=iw*fit*this.zoom,dh=ih*fit*this.zoom;
      this.pan.x=Math.max(-Math.max(0,(dw-aw)/2),Math.min(Math.max(0,(dw-aw)/2),this.pan.x));
      this.pan.y=Math.max(-Math.max(0,(dh-ah)/2),Math.min(Math.max(0,(dh-ah)/2),this.pan.y));
      ctx.save();ctx.beginPath();ctx.rect(0,54,w,h-96);ctx.clip();ctx.drawImage(image,(w-dw)/2+this.pan.x,60+(ah-dh)/2+this.pan.y,dw,dh);ctx.restore();
    }else{
      ctx.fillStyle='#a3a79e';ctx.font='13px "Segoe UI","Microsoft YaHei UI"';ctx.textAlign='center';
      ctx.fillText(entry?.missing?'原照片不可用':'正在读取照片…',w/2,h/2);
    }
  }
}
