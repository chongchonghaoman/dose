// Photo-first editorial mosaics: full images, shared bands and uniform gutters.
// The social square uses its entire area instead of inheriting magazine headers.
(function(root,factory){const api=factory();if(typeof module!=='undefined'&&module.exports)module.exports=api;if(root)root.DoseShareLayout=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  const styles=['editorial','viewport','moments','grid','contact'];
  const finite=(v,d)=>Number.isFinite(v)&&v>0?v:d;
  function photosOf(input){
    const seen=new Set(),out=[];for(const p of Array.isArray(input)?input:[]){
      if(!p||p.id===undefined)continue;const id=String(p.id);if(seen.has(id))continue;seen.add(id);
      const width=finite(p.width,1),height=finite(p.height,1);out.push({id,width,height,aspect:width/height,index:out.length});
    }return out;
  }
  const median=values=>{const v=values.slice().sort((a,b)=>a-b);return v.length?v[Math.floor(v.length/2)]:0;};
  // Dynamic programming chooses complete, justified rows by photo AREA, not
  // arbitrary region weights. Prefix log sums keep each row cost constant-time.
  function partitionRows(sequence,width,height,gap,areaFactor){
    const n=sequence.length,A=[0],logs=[0],log2=[0];
    for(const p of sequence){const l=Math.log(p.a);A.push(A.at(-1)+p.a);logs.push(logs.at(-1)+l);log2.push(log2.at(-1)+l*l);}
    const mean=A[n]/n,target=width*height/n*areaFactor,logTarget=Math.log(target),maxCount=Math.min(n,Math.max(6,Math.ceil(2.4*Math.sqrt(n/mean*width/height))));
    const cost=new Float64Array(n+1).fill(Infinity),previous=new Int32Array(n+1);cost[0]=0;
    for(let end=1;end<=n;end++){
      const low=Math.max(0,end-maxCount);
      for(let start=end-1;start>=low;start--){
        const k=end-start,available=width-(k-1)*gap;if(available<=0)continue;
        const sum=A[end]-A[start],h=available/sum,base=2*Math.log(h)-logTarget;
        const spread=k*base*base+2*base*(logs[end]-logs[start])+log2[end]-log2[start];
        const singleton=n>6&&k===1?6:0,next=cost[start]+spread+singleton;
        if(next<cost[end]){cost[end]=next;previous[end]=start;}
      }
    }
    if(!Number.isFinite(cost[n]))return null;
    const rows=[];for(let end=n;end>0;){const start=previous[end];rows.push({start,end,sum:A[end]-A[start]});end=start;}rows.reverse();
    let inverses=0,gapTerms=0;for(const r of rows){inverses+=1/r.sum;gapTerms+=(r.end-r.start-1)/r.sum;}
    const fittedWidth=Math.min(width,(height-(rows.length-1)*gap+gap*gapTerms)/inverses);if(!(fittedWidth>0))return null;
    for(const r of rows)r.height=(fittedWidth-(r.end-r.start-1)*gap)/r.sum;
    if(rows.some(r=>r.height<=0))return null;
    const usedHeight=rows.reduce((s,r)=>s+r.height,0)+(rows.length-1)*gap;
    return {rows,width:fittedWidth,height:usedHeight,dx:(width-fittedWidth)/2,dy:(height-usedHeight)/2};
  }
  function materialize(sequence,plan,region,gap,axis){
    const items=[],bands=[];let y=plan.dy;
    for(const r of plan.rows){
      let x=plan.dx;const ids=[];
      for(let k=r.start;k<r.end;k++){
        const p=sequence[k],w=r.height*p.a,id='share-'+p.id;
        const item=axis==='rows'?{x:region.x+x+w/2,y:region.y+y+r.height/2,width:w}:{x:region.x+y+r.height/2,y:region.y+x+w/2,width:r.height};
        items.push({id,photoId:p.id,...item,angle:0,presentation:'print',mount:'bare',sprockets:false,group:null});ids.push(id);x+=w+gap;
      }
      bands.push(axis==='rows'?{x:region.x+plan.dx,y:region.y+y,width:plan.width,height:r.height,itemIds:ids}:{x:region.x+y,y:region.y+plan.dx,width:r.height,height:plan.width,itemIds:ids});
      y+=r.height+gap;
    }
    return {items,bands};
  }
  function candidates(photos,region,gap,axisOptions){
    const result=[],seen=new Set(),aspects=new Map(photos.map(p=>[p.id,p.aspect]));
    for(const axis of axisOptions){
      const width=axis==='rows'?region.width:region.height,height=axis==='rows'?region.height:region.width;
      const original=photos.map(p=>({...p,a:axis==='rows'?p.aspect:1/p.aspect})),sorted=original.slice().sort((a,b)=>a.a-b.a||a.index-b.index),woven=[];
      for(let lo=0,hi=sorted.length-1;lo<=hi;lo++,hi--){woven.push(sorted[lo]);if(lo!==hi)woven.push(sorted[hi]);}
      const orders=[original,sorted,sorted.slice().reverse(),woven,woven.slice().reverse()];
      for(const [orderIndex,order] of orders.entries())for(const factor of [.78,1,1.26]){
        const plan=partitionRows(order,width,height,gap,factor);if(!plan)continue;
        const built=materialize(order,plan,region,gap,axis),areas=built.items.map(i=>i.width*i.width/aspects.get(i.photoId)),mid=median(areas),max=Math.max(...areas),total=areas.reduce((a,b)=>a+b,0);
        const key=built.items.map(i=>[i.id,i.x.toFixed(3),i.y.toFixed(3),i.width.toFixed(3)].join(':')).join('|');if(seen.has(key))continue;seen.add(key);
        const spread=areas.reduce((s,a)=>s+Math.log(a/mid)**2,0)/areas.length,coverage=total/(region.width*region.height),ratio=max/mid;
        // Prefer the collection's story order when it packs almost as well.
        const score=coverage-.055*Math.sqrt(spread)-.12*Math.max(0,ratio-2.4)-(orderIndex?0.012:0);
        result.push({...built,axis,coverage,ratio,score});
      }
    }
    return result.sort((a,b)=>b.score-a.score||a.axis.localeCompare(b.axis));
  }
  function composeRegion(photos,region,gap,variant,axes){
    const ranked=candidates(photos,region,gap,axes);if(!ranked.length)throw Error('Unable to compose the square photo grid');
    const best=ranked[0],viable=ranked.filter(c=>c.score>=best.score-.035&&c.coverage>=best.coverage*.95);
    const chosen=viable[variant%Math.min(viable.length,4)]||best;
    return {items:chosen.items,grid:{kind:'justified',version:2,axis:chosen.axis,gap,bands:chosen.bands},coverage:chosen.coverage};
  }
  function metricsOf(items,photos,edge){
    if(!items.length)return {coverage:0,tileCoverage:Array(9).fill(0),maxToMedianArea:0,medianArea:0,medianLongEdge:0};
    const source=new Map(photos.map(p=>[String(p.id),p])),tile=edge/3,area=[],long=[],tileCoverage=Array(9).fill(0);
    for(const i of items){const p=source.get(i.photoId),h=i.width*p.height/p.width,a=i.width*h,x=i.x-i.width/2,y=i.y-h/2;area.push(a);long.push(Math.max(i.width,h));
      for(let row=0;row<3;row++)for(let col=0;col<3;col++){const w=Math.max(0,Math.min(x+i.width,(col+1)*tile)-Math.max(x,col*tile)),height=Math.max(0,Math.min(y+h,(row+1)*tile)-Math.max(y,row*tile));tileCoverage[row*3+col]+=w*height/(tile*tile);}
    }
    const mid=median(area),coverage=area.reduce((a,b)=>a+b,0)/(edge*edge);
    return {coverage,tileCoverage,maxToMedianArea:Math.max(...area)/mid,medianArea:mid,medianLongEdge:median(long),tileSpread:Math.max(...tileCoverage)-Math.min(...tileCoverage)};
  }
  function regionBatches(photos,regions){
    // Neighbouring photographs stay together. Allocate by usable area so an
    // asymmetric region never inherits the same count as a much larger one.
    const weights=regions.map(r=>r.width*r.height),sum=weights.reduce((a,b)=>a+b,0),rest=photos.length-regions.length;
    const exact=weights.map(w=>rest*w/sum),counts=exact.map(v=>1+Math.floor(v));
    const fractions=exact.map((v,i)=>({i,f:v-Math.floor(v)})).sort((a,b)=>b.f-a.f||a.i-b.i);
    for(let k=0,left=photos.length-counts.reduce((a,b)=>a+b,0);k<left;k++)counts[fractions[k].i]++;
    let start=0;return counts.map(n=>{const batch=photos.slice(start,start+n);start+=n;return batch;});
  }
  function editorialRegions(edge,margin,variant,n){
    // Authored 12 x 12 modules share every major edge. The inner photographs
    // then follow justified rows/columns, preserving complete source images.
    const plans=n>=60?[
      [[0,0,7,7],[7,0,5,4],[7,4,5,3],[0,7,4,5],[4,7,8,5]],
      [[0,0,8,5],[8,0,4,5],[0,5,4,7],[4,5,8,7]],
      [[0,0,4,6],[4,0,4,6],[8,0,4,6],[0,6,6,6],[6,6,6,6]]
    ]:[
      [[0,0,7,12],[7,0,5,6],[7,6,5,6]],
      [[0,0,12,5],[0,5,5,7],[5,5,7,7]],
      [[0,0,6,7],[6,0,6,7],[0,7,12,5]]
    ];
    const gutter=edge*.009,unit=(edge-2*margin+gutter)/12,mirror=Math.floor(variant/3)%2;
    return plans[variant%plans.length].map(([x,y,w,h])=>({x:margin+(mirror?12-x-w:x)*unit,y:margin+y*unit,width:w*unit-gutter,height:h*unit-gutter}));
  }
  function layoutSquare(input,options={}){
    const photos=photosOf(input),n=photos.length,edge=finite(options.edge,2400),style=styles.includes(options.style)?options.style:'editorial',variant=Number.isFinite(options.variant)?Math.max(0,Math.floor(options.variant)):0;
    const result={items:[],pages:[],bounds:{x:0,y:0,width:edge,height:edge},style,variant,grids:[]};
    if(!n){result.metrics=metricsOf([],[],edge);return result;}
    const margin=edge*.012,gap=Math.min(edge*.0045,edge/(Math.sqrt(n)*12)),inner=edge-2*margin,regions=[];let batches=[];
    if(style==='moments'&&n>=9){
      const sizes=[edge/3-margin-gap/2,edge/3-gap,edge/3-margin-gap/2],starts=[margin,edge/3+gap/2,edge*2/3+gap/2];
      for(let k=0;k<9;k++){const row=Math.floor(k/3),col=k%3;regions.push({x:starts[col],y:starts[row],width:sizes[col],height:sizes[row]});}
      const count=Math.floor(n/9),extra=n%9;let start=0;for(let k=0;k<9;k++){const size=count+(k<extra?1:0);batches.push(photos.slice(start,start+size));start+=size;}
    }else if(style==='editorial'&&n>=24){
      regions.push(...editorialRegions(edge,margin,variant,n));batches=regionBatches(photos,regions);
    }else{regions.push({x:margin,y:margin,width:inner,height:inner});batches.push(photos);}
    for(let k=0;k<regions.length;k++){
      const axes=style==='grid'?['rows']:style==='contact'?['columns']:(k+variant)%2?['columns','rows']:['rows','columns'];
      const part=composeRegion(batches[k],regions[k],gap,variant+k,axes);result.items.push(...part.items);result.grids.push({...regions[k],grid:part.grid});
    }
    const order=new Map(photos.map(p=>[p.id,p.index]));result.items.sort((a,b)=>order.get(a.photoId)-order.get(b.photoId));
    result.metrics=metricsOf(result.items,photos,edge);return result;
  }
  return {layoutSquare,metricsOf};
});
