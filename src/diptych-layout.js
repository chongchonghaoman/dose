(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoseDiptych=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  const modes=['related','color','place','couple','manual'];
  const placeKey=value=>String(value||'').normalize('NFKC').trim().toLowerCase().replace(/\s+/g,' ');
  const validGPS=g=>g&&Number.isFinite(g.latitude)&&Number.isFinite(g.longitude)&&Math.abs(g.latitude)<=90&&Math.abs(g.longitude)<=180;
  function distance(a,b){
    if(!validGPS(a)||!validGPS(b))return Infinity;
    const rad=Math.PI/180,dlat=(b.latitude-a.latitude)*rad,dlon=(b.longitude-a.longitude)*rad;
    const h=Math.min(1,Math.max(0,Math.sin(dlat/2)**2+Math.cos(a.latitude*rad)*Math.cos(b.latitude*rad)*Math.sin(dlon/2)**2));
    return 12742*Math.atan2(Math.sqrt(h),Math.sqrt(1-h));
  }
  function colorVector(color){
    if(!color||!(color.saturation>.08)||!Array.isArray(color.histogram)||color.histogram.length!==12)return null;
    const h=color.histogram.map(n=>Number.isFinite(n)&&n>0?n:0);
    const smooth=h.map((n,i)=>.6*n+.2*h[(i+11)%12]+.2*h[(i+1)%12]);
    const length=Math.hypot(...smooth);return length>0?smooth.map(n=>n/length):null;
  }
  function evidence(a,b){
    const color=a.vector&&b.vector?Math.min(1,a.vector.reduce((sum,n,i)=>sum+n*b.vector[i],0)):null;
    const location=!!(a.place&&a.place===b.place)||distance(a.photo.gps,b.photo.gps)<=2;
    const delta=Number.isFinite(a.photo.capturedAt)&&Number.isFinite(b.photo.capturedAt)?Math.abs(a.photo.capturedAt-b.photo.capturedAt):Infinity;
    return {color,location,nearTime:delta<=86400000,time:Math.exp(-delta/86400000)};
  }
  function pairPhotos(input,options={}){
    const mode=modes.includes(options.mode)?options.mode:'related',seen=new Set(),photos=[],warnings=[];
    for(const photo of Array.isArray(input)?input:[]){if(!photo||typeof photo.id!=='string'||seen.has(photo.id))continue;seen.add(photo.id);photos.push(photo);if(photos.length===5000)break;}
    if(mode==='manual'){
      const pairs=[];for(let i=0;i+1<photos.length;i+=2)pairs.push({ids:[photos[i].id,photos[i+1].id],reason:'手动配对',score:1});
      return {pairs,unpaired:photos.length%2?[photos.at(-1).id]:[],warnings};
    }
    const entries=photos.map((photo,index)=>({photo,index,place:placeKey(photo.place),vector:colorVector(photo.color)}));
    const byPerson={a:[],b:[]},byPlace=new Map(),byHue=new Map();
    for(const entry of entries){
      if(byPerson[entry.photo.person])byPerson[entry.photo.person].push(entry);
      if(entry.place){if(!byPlace.has(entry.place))byPlace.set(entry.place,[]);byPlace.get(entry.place).push(entry);}
      if(entry.vector){entry.hue=entry.vector.indexOf(Math.max(...entry.vector));if(!byHue.has(entry.hue))byHue.set(entry.hue,[]);byHue.get(entry.hue).push(entry);}
    }
    const pairs=[],used=new Set();
    for(const a of entries){
      if(used.has(a.photo.id))continue;
      const candidates=new Map();
      const take=(list,limit=96)=>{let count=0;for(const b of list||[]){if(b===a||used.has(b.photo.id))continue;candidates.set(b.photo.id,b);if(++count>=limit)break;}};
      if(mode==='couple'){
        if(!['a','b'].includes(a.photo.person))continue;
        take(byPerson[a.photo.person==='a'?'b':'a'],256);
      }else{
        if(mode==='related'||mode==='place'){
          if(a.place)take(byPlace.get(a.place),128);
          if(validGPS(a.photo.gps)){let count=0;for(const b of entries){if(b!==a&&!used.has(b.photo.id)&&distance(a.photo.gps,b.photo.gps)<=2){candidates.set(b.photo.id,b);if(++count>=128)break;}}}
        }
        if(mode==='related'||mode==='color'){
          if(a.vector)for(const shift of [0,-1,1])take(byHue.get((a.hue+shift+12)%12),96);
          take(entries.slice(a.index+1,a.index+129),128);
        }
      }
      let best=null;
      for(const b of candidates.values()){
        const e=evidence(a,b);let score;
        if(mode==='place'){if(!e.location)continue;score=.8+.15*(e.color||0)+.05*e.time;}
        else if(mode==='couple')score=.1+.5*(e.color||0)+.3*Number(e.location)+.1*e.time;
        else{if(mode==='color'?e.color==null||e.color<.5:!e.location&&(e.color==null||e.color<.5))continue;score=mode==='color'?e.color:Math.max(.8*Number(e.location),.7*(e.color||0))+.1*e.time;}
        if(!best||score>best.score+1e-9)best={b,e,score};
      }
      if(!best)continue;
      let ids=[a.photo.id,best.b.photo.id];if(mode==='couple'&&a.photo.person==='b')ids.reverse();
      const reason=mode==='couple'?'双人 A+B':mode!=='color'&&best.e.location?'同一地点':mode==='related'&&best.e.nearTime?'相近色彩 · 同日拍摄':'相近色彩';
      pairs.push({ids,reason,score:Number(best.score.toFixed(4))});ids.forEach(id=>used.add(id));
    }
    const unpaired=photos.filter(p=>!used.has(p.id)).map(p=>p.id);
    if(mode==='place'&&!entries.some(e=>e.place||validGPS(e.photo.gps)))warnings.push('照片没有可用的 GPS，请填写地点名称。');
    if(mode==='couple'&&(!byPerson.a.length||!byPerson.b.length))warnings.push('分别标记人物 A 和 B，每页各取一张。');
    return {pairs,unpaired,warnings};
  }
  function layoutPairs(pairs,options={}){
    const width=Number.isFinite(options.width)&&options.width>0?options.width:1000;
    const gap=Number.isFinite(options.gap)&&options.gap>=0?options.gap:32;
    const ox=Number.isFinite(options.origin?.x)?options.origin.x:0,oy=Number.isFinite(options.origin?.y)?options.origin.y:0;
    const height=width*1.5,seam=width*.008,slot=(height-seam)/2,pages=[],items=[],used=new Set();
    for(const pair of pairs||[]){
      if(!Array.isArray(pair?.ids)||pair.ids.length!==2||pair.ids[0]===pair.ids[1]||pair.ids.some(id=>used.has(id)))continue;
      const index=pages.length,x=ox+(index%3)*(width+gap),y=oy+Math.floor(index/3)*(height+gap);
      pages.push({x,y,width,height,itemIds:[...pair.ids],number:index+1,kind:'diptych',composition:'diptych',pairReason:pair.reason,background:'#ffffff'});
      pair.ids.forEach((id,k)=>{used.add(id);items.push({id,x:x+width/2,y:y+k*(slot+seam)+slot/2,width,height:slot,crop:{x:.5,y:.5,zoom:1},presentation:'print',angle:0});});
    }
    return {pages,items};
  }
  return {pairPhotos,layoutPairs};
});
