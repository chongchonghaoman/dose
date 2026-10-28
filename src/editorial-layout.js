// Deterministic, dependency-free photo layouts. Coordinates are image centres.
(function (root, factory) {
  const api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.DoseLayout = api;
})(typeof self !== 'undefined' ? self : typeof globalThis !== 'undefined' ? globalThis : this, function () {
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const finite = (v, fallback) => Number.isFinite(v) && v > 0 ? v : fallback;

  function normalize(items) {
    return (Array.isArray(items) ? items : []).map((item, index) => ({
      id: item && item.id !== undefined ? item.id : index,
      aspect: finite(item && item.aspect, 1),
      insets: { x: finite(item && item.frameInsets && item.frameInsets.x, 0), y: finite(item && item.frameInsets && item.frameInsets.y, 0) },
      hero: !!(item && item.hero)
    }));
  }
  // A real column/baseline grid underpins every editorial composition. Dense
  // pages subdivide the SAME twelve parent columns, retaining their edges.
  const PAGE = { width:849, height:1200 };
  const FAMILIES=['stagger','diagonal','columns','panorama','islands','portrait'];
  function hash(text){let h=2166136261;for(let i=0;i<text.length;i++){h^=text.charCodeAt(i);h=Math.imul(h,16777619);}return h>>>0;}
  function gridSpec(width,height,subdivisions=1){
    const d=clamp(Math.floor(subdivisions)||1,1,1024),scale=Math.min(width/849,height/1200),baseline=8*scale/d,parentGutter=16*scale,gutter=parentGutter/d,margin=48*scale;
    const parentWidth=(width-2*margin-11*parentGutter)/12,childWidth=(parentWidth-(d-1)*gutter)/d,step=childWidth+gutter,lefts=[],rights=[];
    for(let c=0;c<12*d;c++){const left=margin+Math.floor(c/d)*(parentWidth+parentGutter)+(c%d)*step;lefts.push(left);rights.push(left+childWidth);}
    // Reserve a modest paper margin, not an empty title block on every page.
    // Folios remain below the image area at 96% of the paper height.
    const top=Math.ceil(height*.072/baseline-1e-8)*baseline,rows=Math.max(6,Math.floor((height*.92-top)/baseline+1e-8));
    return {width,height,columns:12,subdivisions:d,baseline,parentGutter,gutter,margin,top,rows,lefts,rights};
  }
  function gridFor(items,target,minimum=1){
    const base=gridSpec(target.width,target.height),minimumAspect=Math.min(...items.map(p=>p.aspect*(1+2*p.insets.x)/(1+2*p.insets.y))),rowBudget=(target.height*.74)/(Math.ceil(Math.sqrt(items.length))+2);
    const subdivisions=Math.max(2,minimum,Math.ceil(Math.sqrt(items.length/8)),Math.ceil(2*(base.rights[0]-base.lefts[0])/(minimumAspect*rowBudget)));
    return gridSpec(target.width,target.height,subdivisions);
  }
  function rectOf(g,r){return {x:g.lefts[r.c],y:g.top+r.r*g.baseline,w:g.rights[r.c+r.cs-1]-g.lefts[r.c],h:r.rs*g.baseline-g.gutter};}
  function distribute(n,weights){
    const out=weights.map(()=>0);
    if(n<weights.length){for(let i=0;i<n;i++)out[n===1?0:Math.round(i*(weights.length-1)/(n-1))]=1;return out;}
    out.fill(1);const rest=n-weights.length,sum=weights.reduce((a,b)=>a+b,0),fractions=weights.map((w,i)=>{const exact=rest*w/sum,whole=Math.floor(exact);out[i]+=whole;return {i,f:exact-whole};});
    let remaining=n-out.reduce((a,b)=>a+b,0);fractions.sort((a,b)=>b.f-a.f||a.i-b.i);for(let i=0;i<remaining;i++)out[fractions[i].i]++;return out;
  }
  function partition(region,n,axis,g,average,proposal,out,depth=0){
    if(!n)return;
    if(n===1){out.push({...rectOf(g,region),...region});return;}
    const first=n===3?(proposal%2?2:1):Math.floor(n/2),rows=Math.floor(region.rs/3);
    const xlo=Math.max(1,Math.ceil(first/rows)),xhi=region.cs-Math.max(1,Math.ceil((n-first)/rows));
    const ylo=Math.max(3,3*Math.ceil(first/region.cs)),yhi=region.rs-Math.max(3,3*Math.ceil((n-first)/region.cs));
    const b=rectOf(g,region);let dir=axis||(b.w/b.h>average*(proposal>=2?1.25:.8)?'x':'y');
    if(dir==='x'&&xlo>xhi)dir='y';if(dir==='y'&&ylo>yhi)dir='x';
    if(dir==='x'){
      if(xlo>xhi)throw new RangeError('Insufficient grid columns');
      const cut=clamp(Math.round(region.cs*first/n),xlo,xhi);
      partition({...region,cs:cut},first,null,g,average,proposal,out,depth+1);
      partition({...region,c:region.c+cut,cs:region.cs-cut},n-first,null,g,average,proposal,out,depth+1);
    }else{
      if(ylo>yhi)throw new RangeError('Insufficient baseline rows');
      const cut=clamp(Math.round(region.rs*first/n),ylo,yhi);
      partition({...region,rs:cut},first,null,g,average,proposal,out,depth+1);
      partition({...region,r:region.r+cut,rs:region.rs-cut},n-first,null,g,average,proposal,out,depth+1);
    }
  }
  function composeBoxes(family,items,edition,proposal,g){
    const wide=edition%4>=2,mirror=edition%2===1,portraits=items.filter(p=>p.aspect<.9).length/items.length;
    // c/span use the twelve parent columns; y/end use shared baseline bands.
    // Each alternate is an authored modular plan, never a coordinate jitter.
    let zones,weights,counts;
    const dense=items.length>12,shift=proposal%2?0.035:0,band=.34+shift;
    if(family==='stagger'){
      zones=[[wide?1:2,wide?11:10,0,.31+shift,'x'],[0,12,.33+shift,.64,'x'],[wide?0:1,wide?12:11,.66,1,'x']];weights=[2,3,3];
    }else if(family==='diagonal'){
      zones=[[0,wide?11:10,0,.31,'x'],[wide?1:2,wide?11:10,.33,.65+shift,'x'],[0,wide?12:11,.67+shift,1,'x']];weights=[3,2,3];
    }else if(family==='columns'){
      zones=[[0,wide?6:5,0,.96,'y'],[wide?6:5,wide?6:7,.035+shift,1,'y']];weights=[3+portraits*2,5-portraits*2];
    }else if(family==='panorama'){
      zones=[[0,12,0,band,'x'],[0,wide?6:5,band+.025,1,'y'],[wide?6:5,wide?6:7,band+.025,1,'y']];weights=[2,3,3];
      if(items.length>=4&&!dense)counts=[1,Math.ceil((items.length-1)/2),Math.floor((items.length-1)/2)];
    }else if(family==='islands'){
      zones=[[0,wide?7:6,0,.43+shift,'x'],[wide?7:6,wide?5:6,.04,.43+shift,'y'],[0,wide?5:6,.46+shift,1,'y'],[wide?5:6,wide?7:6,.46+shift,.96,'y']];weights=[2,2,2,2];
    }else{
      zones=[[0,wide?6:5,0,.67+shift,'y'],[wide?6:5,wide?6:7,0,.67+shift,'y'],[0,12,.70+shift,1,'x']];weights=dense?[3,3,2]:[1,4,3];
      if(items.length>2&&!dense)counts=[1,Math.ceil((items.length-1)*.55),Math.floor((items.length-1)*.45)];
    }
    if(items.length===1){
      const f=FAMILIES.indexOf(family),span=[12,10,9,11,8,10][f],c=mirror?12-span:Math.floor((12-span)/2),r=Math.round((f%3)*.035*g.rows);
      return [{...rectOf(g,{c:c*g.subdivisions,cs:span*g.subdivisions,r,rs:g.rows-r}),c:c*g.subdivisions,cs:span*g.subdivisions,r,rs:g.rows-r,edge:mirror?'right':'left'}];
    }
    counts=counts||distribute(items.length,weights);const boxes=[],average=items.reduce((s,p)=>s+clamp(p.aspect,.2,5),0)/items.length;
    for(let i=0;i<zones.length;i++){
      const [column,span,top,end,axis]=zones[i],r=Math.round(top*g.rows),last=Math.round(end*g.rows);
      const region={c:(mirror?12-column-span:column)*g.subdivisions,cs:span*g.subdivisions,r,rs:last-r,edge:mirror?'right':'left'};
      partition(region,counts[i],axis,g,average,proposal,boxes);
    }
    return boxes;
  }
  function assign(items, slots) {
    // At most eight photos: a bitmask assignment keeps portraits in tall slots
    // and wide photos in wide slots. A small order cost preserves stable story
    // order when aspect ratios are alike, independent of canvas stacking order.
    const aspect=p=>p.aspect*(1+2*p.insets.x)/(1+2*p.insets.y),n=items.length;
    if(n>8){
      // Dense window layouts use sorted aspect matching, keeping every photo
      // without the exponential assignment used for small magazine pages.
      const photos=items.map((p,i)=>({i,aspect:aspect(p)})).sort((a,b)=>a.aspect-b.aspect||a.i-b.i),boxes=slots.map((s,i)=>({i,aspect:s.w/s.h})).sort((a,b)=>a.aspect-b.aspect||a.i-b.i),indices=[];let cost=0;
      for(let i=0;i<n;i++){indices[boxes[i].i]=photos[i].i;cost+=Math.log(photos[i].aspect/boxes[i].aspect)**2;}
      return {indices,cost};
    }
    const limit=1<<n,memo=new Map();
    function solve(mask,k){
      if(mask===limit-1)return {cost:0,indices:[]};
      if(memo.has(mask))return memo.get(mask);let best={cost:Infinity,indices:[]};
      for(let i=0;i<n;i++)if(!(mask&(1<<i))){
        const shape=Math.log(aspect(items[i])/(slots[k].w/slots[k].h));
        const next=solve(mask|(1<<i),k+1),cost=shape*shape+.06*Math.abs(i-k)/Math.max(1,n-1)+next.cost;
        if(cost<best.cost)best={cost,indices:[i,...next.indices]};
      }
      memo.set(mask,best);return best;
    }
    return solve(0,0);
  }

  function imageFit(p,b,g){
    const maxWidth=Math.min(b.w,b.h*p.aspect*(1+2*p.insets.x)/(1+2*p.insets.y));
    let lo=1,hi=b.cs,span=0;
    while(lo<=hi){const m=(lo+hi)>>1,w=g.rights[b.c+m-1]-g.lefts[b.c];if(w<=maxWidth+1e-8){span=m;lo=m+1;}else hi=m-1;}
    // A right-aligned region must measure from its right edge, including the
    // wider gutters between parent columns.
    if(b.edge==='right'){span=0;lo=1;hi=b.cs;while(lo<=hi){const m=(lo+hi)>>1,w=g.rights[b.c+b.cs-1]-g.lefts[b.c+b.cs-m];if(w<=maxWidth+1e-8){span=m;lo=m+1;}else hi=m-1;}}
    if(!span)return null;
    const c=b.edge==='right'?b.c+b.cs-span:b.c,ow=g.rights[c+span-1]-g.lefts[c],width=ow/(1+2*p.insets.x),oh=width/p.aspect*(1+2*p.insets.y);
    return {width,ow,oh,x:g.lefts[c]+ow/2,y:b.y+oh/2};
  }
  function candidates(items,edition,target={width:849,height:1200},minimum=1){
    let g=gridFor(items,target,minimum);
    for(let attempt=0;attempt<7;attempt++){
      const ranked=FAMILIES.map(family=>{
        let best;
        for(let proposal=0;proposal<4;proposal++){
          const boxes=composeBoxes(family,items,edition,proposal,g),match=assign(items,boxes),fits=boxes.map((b,k)=>imageFit(items[match.indices[k]],b,g));
          if(fits.some(p=>!p))continue;
          let imageArea=0,boxArea=0,min=Infinity,max=0,fullColumns=0;
          for(let k=0;k<boxes.length;k++){const b=boxes[k],p=items[match.indices[k]],f=fits[k],area=f.width*f.width/p.aspect;imageArea+=area;boxArea+=b.w*b.h;min=Math.min(min,area);max=Math.max(max,area);if(Math.abs(f.ow-b.w)<1e-7)fullColumns++;}
          const utilization=imageArea/boxArea,coverage=imageArea/(target.width*target.height*.74),tiny=Math.max(0,.12-min/max),flat=Math.max(0,1.3/items.length-max/imageArea);
          const medianArea=fits.map((f,k)=>f.width*f.width/items[match.indices[k]].aspect).sort((a,b)=>a-b)[Math.floor(items.length/2)];
          const dominant=Math.max(0,max/medianArea-(items.length>12?3:6));
          const score=.4*utilization+.5*coverage+.10*fullColumns/items.length-.35*tiny-.12*flat-.035*dominant-.015*match.cost/items.length;
          if(!best||score>best.score)best={family,boxes,indices:match.indices,fits,score,proposal,grid:g};
        }
        return best;
      });
      if(ranked.every(Boolean))return ranked.sort((a,b)=>b.score-a.score||FAMILIES.indexOf(a.family)-FAMILIES.indexOf(b.family));
      if(g.subdivisions>=1024)break;
      g=gridSpec(target.width,target.height,g.subdivisions*2);
    }
    throw new RangeError('Unable to fit photos on the editorial grid');
  }
  function gridRecord(g){return {version:1,columns:12,subdivisions:g.subdivisions};}
  function layoutViewport(input,options={}){
    const items=normalize(input),width=finite(options.width,1000),height=finite(options.height,700),variant=Number.isFinite(options.variant)?Math.max(0,Math.floor(options.variant)):0;
    if(!items.length)return {items:[],pages:[],bounds:{x:0,y:0,width,height},metrics:{composition:'',photos:0}};
    const seed=hash(items.map(p=>String(p.id)+':'+p.aspect.toFixed(4)).join('|')),target={width,height},ranked=candidates(items,Math.floor(variant/FAMILIES.length),target,options.gridSubdivisions||1);
    let rank=variant%ranked.length;if(options.avoidComposition===ranked[rank].family)rank=(rank+1)%ranked.length;
    let chosen=ranked[rank];
    if(options.composition&&ranked.some(c=>c.family===options.composition))chosen=ranked.find(c=>c.family===options.composition);
    const out=new Array(items.length),ids=[];
    for(let k=0;k<chosen.boxes.length;k++){const i=chosen.indices[k],p=items[i],f=chosen.fits[k];out[i]={id:p.id,x:f.x,y:f.y,width:f.width};ids.push(p.id);}
    return {items:out,pages:[{x:0,y:0,width,height,number:1,itemIds:ids,kind:'viewport',composition:chosen.family,variant,seed,grid:gridRecord(chosen.grid)}],bounds:{x:0,y:0,width,height},metrics:{composition:chosen.family,photos:items.length}};
  }
  function storyPage(items,{width=849,height=1200,variant=0,role='story',avoidComposition}={}){
    const hero=items.findIndex(p=>p.hero),target={width,height};
    if(hero>=0&&items.length>1){
      // Give the main photo a dedicated region, then constrain the actual
      // image area of its companions. Slot size alone cannot guarantee this.
      for(let attempt=0;attempt<8;attempt++){
        const g=gridFor(items,target,4*2**attempt),d=g.subdivisions,side=items[hero].aspect<.95,mirror=variant%2===1;
        const band=variant%3,mainSpan=[8,7,8][band],split=Math.round(g.rows*[.63,.59,.66][band]),gapRows=Math.max(2,Math.ceil(g.parentGutter/g.baseline));
        const main=side?{c:(mirror?12-mainSpan:0)*d,cs:mainSpan*d,r:0,rs:g.rows,edge:mirror?'right':'left'}:{c:0,cs:12*d,r:0,rs:split,edge:mirror?'right':'left'};
        const rest=side?{c:(mirror?0:mainSpan)*d,cs:(12-mainSpan)*d,r:0,rs:g.rows}:{c:0,cs:12*d,r:split+gapRows,rs:g.rows-split-gapRows};
        const mainBox={...rectOf(g,main),...main},mainFit=imageFit(items[hero],mainBox,g);
        if(!mainFit)continue;
        const indices=[hero,...items.map((_,i)=>i).filter(i=>i!==hero)],boxes=[mainBox];
        partition(rest,items.length-1,side?'y':'x',g,1.3,variant%4,boxes);
        const maxArea=mainFit.width**2/items[hero].aspect/1.65;
        const fits=[mainFit,...boxes.slice(1).map((b,k)=>imageFit(items[indices[k+1]],{...b,w:Math.min(b.w,Math.sqrt(maxArea*items[indices[k+1]].aspect))},g))];
        if(fits.some(f=>!f))continue;
        if(side&&items.length<=8){
          const companions=fits.slice(1),required=companions.reduce((sum,f)=>sum+Math.ceil(f.oh/g.baseline)*g.baseline,0),available=g.rows*g.baseline-required;
          const gapRows=Math.max(0,Math.min(Math.ceil(g.parentGutter/g.baseline),Math.floor(available/Math.max(1,companions.length-1)/g.baseline)));
          let row=0;for(const fit of companions){fit.y=g.top+row*g.baseline+fit.oh/2;row+=Math.ceil(fit.oh/g.baseline)+gapRows;}
        }
        return {fits,indices,grid:g,composition:'hero-'+(side?'side':'top')+'-'+(variant%6),heroId:items[hero].id};
      }
      throw new RangeError('Unable to fit the main photograph');
    }
    const ranked=candidates(items,Math.floor(variant/FAMILIES.length),target);
    let rank=variant%ranked.length;if(ranked[rank].family===avoidComposition)rank=(rank+1)%ranked.length;
    const chosen=ranked[rank],g=chosen.grid;
    if(items.length===1){
      // A solitary image has a deliberate position on the paper instead of
      // inheriting the top edge of an empty group container.
      const f=chosen.fits[0],bias=role==='closing'?.56:.46;
      const free=Math.max(0,g.rows*g.baseline-f.oh);
      const row=Math.round(free*bias/g.baseline);
      f.y=g.top+row*g.baseline+f.oh/2;
    }
    return {...chosen,composition:chosen.family,heroId:hero>=0?items[hero].id:null};
  }
  function pagePlan(n,moments){
    if(!n)return [];
    const count=moments?Math.min(9,n):n<=2?1:n<=4?2:n<=12?Math.ceil(n/2):Math.max(3,Math.ceil((n-2)/4)+2);
    if(count===1)return [n];
    if(count===2)return [1,n-1];
    // For a fixed nine-page book, sparse pages still grow with large sets.
    const edge=moments?Math.max(1,Math.floor(n/count*.5)):1;
    const sizes=Array(count).fill(1);sizes[0]=sizes[count-1]=edge;
    let remaining=n-sizes.reduce((a,b)=>a+b,0);
    const weights=Array.from({length:count-2},(_,i)=>[1.2,.8,1.4,.55][i%4]);
    const additions=distribute(remaining,weights);
    for(let i=1;i<count-1;i++)sizes[i]+=additions[i-1];
    return sizes;
  }
  function reflowPage(input, page) {
    // Page membership is the scope of a local reflow, even if only one of its
    // photos is selected. Keep paper identity, numbering and ordering intact.
    const byId=new Map(normalize(input).map(p=>[p.id,p])),ids=page.itemIds;
    if(!Array.isArray(ids)||!ids.length||new Set(ids).size!==ids.length||ids.some(id=>!byId.has(id)))throw new RangeError('A page reflow requires every page member');
    const variant=((Number.isFinite(page.variant)?Math.max(0,Math.floor(page.variant)):0)%1000000)+1;
    const members=ids.map(id=>({...byId.get(id),insets:{x:0,y:0},hero:page.heroId?id===page.heroId:byId.get(id).hero}));
    const chosen=storyPage(members,{width:page.width,height:page.height,variant,role:page.role,avoidComposition:page.composition});
    const items=chosen.indices.map((index,k)=>({id:members[index].id,x:chosen.fits[k].x+page.x,y:chosen.fits[k].y+page.y,width:chosen.fits[k].width,presentation:'print'}));
    return {items,page:{...page,itemIds:ids.slice(),composition:chosen.composition,variant,grid:gridRecord(chosen.grid),heroId:chosen.heroId}};
  }
  function editorial(items, width, gap, ox, oy, variant, moments=false) {
    if(!items.length)return {items:[],pages:[],width,height:0};
    // Moments is intentionally a contact-like nine-page story. Editorial is a
    // whole-book rhythm: opening and closing pages breathe, while the middle
    // carries compact image groups. Keep source order; never semantic-sort it.
    const sizes=pagePlan(items.length,moments),count=sizes.length;
    const cols=moments?Math.min(3,count):Math.ceil(Math.sqrt(count*PAGE.height/PAGE.width));
    const scale=width/PAGE.width,pageH=PAGE.height*scale,pageGap=Math.max(gap,width*.055),out=[],pages=[];
    let start=0,previousFamily='';
    for(let page=0;page<count;page++){
      const n=sizes[page],batch=items.slice(start,start+n),seed=hash(batch.map(p=>String(p.id)+':'+p.aspect.toFixed(4)).join('|'));
      const role=page===0?'opening':page===count-1?'closing':n<=2?'pause':'story';
      const chosen=storyPage(batch,{variant:variant+page,role,avoidComposition:previousFamily}),indices=chosen.indices;
      previousFamily=chosen.composition;
      const x=ox+(page%cols)*(width+pageGap),y=oy+Math.floor(page/cols)*(pageH+pageGap);
      // Metadata follows the authored reading order, independent of the
      // geometry solver's aspect-to-slot assignment.
      const pageItems=batch.map(p=>p.id);
      for(let k=0;k<n;k++){
        const i=start+indices[k],p=items[i],f=chosen.fits[k];
        out[i]={id:p.id,x:x+f.x*scale,y:y+f.y*scale,width:f.width*scale,presentation:'print'};
      }
      pages.push({x,y,width,height:pageH,number:page+1,itemIds:pageItems,composition:chosen.composition,variant:variant+page,seed,grid:gridRecord(chosen.grid),kind:moments?'moments':'magazine',role,heroId:chosen.heroId});start+=n;
    }
    return {items:out,pages,width:Math.min(cols,count)*(width+pageGap)-pageGap,height:Math.ceil(count/cols)*(pageH+pageGap)-pageGap};
  }
  function grid(items, width, gap, ox, oy, contact) {
    const n = items.length; if (!n) return { items: [], height: 0 };
    const cols = n <= 2 ? n : n <= 6 ? 3 : n <= 12 ? 4 : 5;
    const cellW = (width - gap * (cols - 1)) / cols;
    const cellH = contact ? cellW * 1.25 : null;
    const out = []; let y = oy;
    for (let i = 0; i < n; i += cols) {
      const count = Math.min(cols, n - i);
      const rowH = contact ? cellH : Math.max.apply(Math, items.slice(i, i + count).map(x => (cellW / (1 + 2 * x.insets.x)) / x.aspect * (1 + 2 * x.insets.y)));
      for (let j = 0; j < count; j++) {
        const item = items[i + j], cellX = ox + j * (cellW + gap);
        const imageW = contact ? Math.min(cellW / (1 + 2 * item.insets.x), (rowH / (1 + 2 * item.insets.y)) * item.aspect) : Math.min(cellW / (1 + 2 * item.insets.x), (rowH / (1 + 2 * item.insets.y)) * item.aspect);
        out[i + j] = { id: item.id, x: cellX + cellW / 2, y: y + rowH / 2, width: imageW };
      }
      y += rowH + gap;
    }
    return { items: out, height: y - oy - gap };
  }
  function layoutPhotos(input, options) {
    const opts = options || {}, mode = ['editorial', 'moments', 'grid', 'contact'].includes(opts.style) ? opts.style : 'editorial';
    const items=normalize(input);if(mode==='editorial'||mode==='moments')for(const p of items)p.insets={x:0,y:0};
    const origin = opts.origin || {}, ox = Number.isFinite(origin.x) ? origin.x : 0, oy = Number.isFinite(origin.y) ? origin.y : 0;
    const width = finite(opts.availableWidth, 1000), gap = clamp(Number.isFinite(opts.gap)?opts.gap:20, 0, width / 24);
    const variant=Number.isFinite(opts.variant)?Math.max(0,Math.floor(opts.variant)):0;
    const result = mode === 'editorial'||mode === 'moments' ? editorial(items, width, gap, ox, oy,variant,mode==='moments') : grid(items, width, gap, ox, oy, mode === 'contact');
    return { items: result.items, pages:result.pages||[], bounds: { x: ox, y: oy, width:result.width||width, height: result.height } };
  }
  return { layoutPhotos,layoutViewport,reflowPage,gridSpec };
});
