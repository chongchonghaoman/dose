// Display geometry only. This module is never loaded by photo export workers.
(function(root,factory){const api=factory();if(typeof module!=='undefined'&&module.exports)module.exports=api;if(root)root.DoseFilmFrame=api;})(typeof self!=='undefined'?self:globalThis,function(){
  function metrics(w,h,mount='bare',enabled=true){
    const border=mount==='slide'?Math.max(w,h)*.13:0,film=!border&&enabled;
    const mx=border||(film?w*(w>=h?.02:.18):0),my=border||(film?h*(w>=h?.18:.02):0);
    return {w,h,ow:w+mx*2,oh:h+my*2,border,film,mx,my};
  }
  function holes(g){
    if(!g.film)return [];
    const horizontal=g.w>=g.h,long=horizontal?g.w:g.h,margin=horizontal?g.my:g.mx;
    const n=Math.max(4,Math.min(16,Math.round((horizontal?g.w/g.h:g.h/g.w)*5.3))),pitch=long/n;
    const along=pitch*.44,across=Math.min(margin*.5,pitch*.5),out=[];
    for(let i=0;i<n;i++)for(const side of [-1,1]){
      const p=-long/2+pitch*(i+.5);
      out.push(horizontal?{x:p-along/2,y:side*(g.h/2+margin*.57)-across/2,w:along,h:across}:{x:side*(g.w/2+margin*.57)-across/2,y:p-along/2,w:across,h:along});
    }return out;
  }
  function paint(ctx,g,{number=1,stock='DOSE',lamp=1,labels=true}={}){
    const cutouts=holes(g);ctx.beginPath();ctx.roundRect(-g.ow/2,-g.oh/2,g.ow,g.oh,1.5);
    for(const hole of cutouts)ctx.roundRect(hole.x,hole.y,hole.w,hole.h,Math.min(hole.w,hole.h)*.18);
    ctx.fillStyle=lamp>.3?'#201d16':'#100f0d';ctx.fill('evenodd');ctx.shadowColor='transparent';
    if(!labels)return cutouts.length;
    ctx.save();const horizontal=g.w>=g.h;if(!horizontal)ctx.rotate(-Math.PI/2);
    const w=horizontal?g.w:g.h,h=horizontal?g.h:g.w,m=horizontal?g.my:g.mx;
    ctx.fillStyle=lamp>.3?'#b9a575':'#746746';ctx.font=`${Math.max(3,w*.018)}px Consolas,monospace`;ctx.textAlign='left';
    ctx.fillText(stock.replace(/^Kodak |^Fujifilm /,'').toUpperCase().slice(0,25),-w*.47,-h/2-m*.12);
    ctx.textAlign='right';ctx.fillText(String(number).padStart(2,'0')+' ▷',w*.47,h/2+m*.23);ctx.restore();
    return cutouts.length;
  }
  return {metrics,holes,paint};
});
