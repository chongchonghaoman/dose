(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoseShareGrid=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  const clamp=(v,a,b)=>Math.max(a,Math.min(b,v)),finite=(v,d)=>Number.isFinite(v)?v:d;
  const rect=c=>({x:c.x-c.size/2,y:c.y-c.size/2,w:c.size,h:c.size});
  function constrain(c,focus={x:1200,y:1200}){
    const size=clamp(finite(c.size,2400),8,50000),lens=clamp(finite(c.lens,.14),.06,.30),inset=size*lens*1.06;
    return {x:size/2,y:size/2,size,focusId:String(c.focusId||focus.id||''),lensX:clamp(finite(c.lensX,focus.x),inset,size-inset),lensY:clamp(finite(c.lensY,focus.y),inset,size-inset),mag:clamp(finite(c.mag,1.5),1,8),lens,background:c.background==='dark'?'dark':'light'};
  }
  function initial(item,photo,edge=2400){return constrain({size:edge,focusId:item.id,lensX:item.x,lensY:item.y},item);}
  function imageBounds(item,photo){const w=item.width,h=w*photo.height/photo.width,a=item.angle*Math.PI/180,c=Math.abs(Math.cos(a)),s=Math.abs(Math.sin(a));return {x:item.x-(w*c+h*s)/2,y:item.y-(h*c+w*s)/2,w:w*c+h*s,h:h*c+w*s};}
  const intersects=(a,b)=>a.x+a.w>=b.x&&a.x<=b.x+b.w&&a.y+a.h>=b.y&&a.y<=b.y+b.h;
  function plan(crop,focus,edge){
    const view=rect(crop),scale=edge/crop.size,r=crop.size*crop.lens,sampleX=crop.lensX,sampleY=crop.lensY;
    return {view,scale,cx:(sampleX-view.x)*scale,cy:(sampleY-view.y)*scale,r:r*scale,sampleX,sampleY,lensView:{x:sampleX-r/crop.mag,y:sampleY-r/crop.mag,w:2*r/crop.mag,h:2*r/crop.mag}};
  }
  function hit(items,photos,p){return [...items].reverse().find(item=>{const photo=photos.get(item.photoId);if(!photo)return false;const a=-item.angle*Math.PI/180,dx=p.x-item.x,dy=p.y-item.y;return Math.abs(dx*Math.cos(a)-dy*Math.sin(a))<=item.width/2&&Math.abs(dx*Math.sin(a)+dy*Math.cos(a))<=item.width*photo.height/photo.width/2;});}
  function imageSize(item,photo,scale){const need=Math.max(item.width,item.width*photo.height/photo.width)*scale;return [48,96,320,800,1600,2400,3200,4320,6000].find(n=>n>=need)||6000;}
  function paintPhoto(ctx,item,photo,image){ctx.save();ctx.translate(item.x,item.y);ctx.rotate(item.angle*Math.PI/180);let w=item.width,h=w*photo.height/photo.width;if(photo.adjustments?.engine==='spectral'&&photo.adjustments?.spectralEdge){const iw=image.naturalWidth||image.width,ih=image.naturalHeight||image.height,s=Math.min(w/iw,h/ih);w=iw*s;h=ih*s;}ctx.drawImage(image,-w/2,-h/2,w,h);ctx.restore();}
  function paintLens(ctx,p,draw){ctx.save();ctx.shadowColor='#070b0466';ctx.shadowBlur=p.r*.12;ctx.shadowOffsetY=p.r*.065;ctx.fillStyle='#292c25';ctx.beginPath();ctx.arc(p.cx,p.cy,p.r*1.045,0,Math.PI*2);ctx.fill();ctx.restore();ctx.save();ctx.beginPath();ctx.arc(p.cx,p.cy,p.r,0,Math.PI*2);ctx.clip();draw();ctx.restore();const rim=ctx.createLinearGradient(p.cx-p.r,p.cy-p.r,p.cx+p.r,p.cy+p.r);for(const [at,color]of [[0,'#c4c6bd'],[.18,'#6e7566'],[.42,'#292f24'],[.7,'#0d130a'],[1,'#939b86']])rim.addColorStop(at,color);ctx.strokeStyle=rim;ctx.lineWidth=p.r*.054;ctx.beginPath();ctx.arc(p.cx,p.cy,p.r*1.025,0,Math.PI*2);ctx.stroke();ctx.strokeStyle='#ffffff9c';ctx.lineWidth=Math.max(.7,p.r*.008);ctx.beginPath();ctx.arc(p.cx,p.cy,p.r*.992,Math.PI*1.05,Math.PI*1.8);ctx.stroke();}
  const background=c=>c.background==='dark'?'#171918':'#e8e6e3';
  return {constrain,initial,rect,imageBounds,intersects,plan,hit,imageSize,paintPhoto,paintLens,background};
});
