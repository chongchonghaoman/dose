const path = require('node:path');
const { cleanAdjustments } = require('./film.cjs');
const EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff', '.avif', '.gif', '.heic', '.heif', '.dng']);
function supported(file) { return EXTENSIONS.has(path.extname(file).toLowerCase()); }
function finite(v, fallback, lo, hi) { return typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : fallback; }
function cleanState(s) {
  if (!s || typeof s !== 'object') return { version: 1, photos: [], items: [] };
  const photos = (Array.isArray(s.photos) ? s.photos : []).filter(p => p && typeof p.path === 'string' && path.isAbsolute(p.path) && supported(p.path)).slice(0, 5000).map(p => ({ id: String(p.id).slice(0, 80), path: p.path, name: path.basename(p.path), width: finite(p.width, 1500, 1, 100000), height: finite(p.height, 1000, 1, 100000), adjustments: cleanAdjustments(p.adjustments), ...(p.referenceDeveloped===true?{referenceDeveloped:true,nativeFrame:p.nativeFrame===true}:{}) }));
  const ids = new Set(photos.map(p => p.id));
  const sourcePhotos=new Map((Array.isArray(s.photos)?s.photos:[]).filter(Boolean).map(p=>[String(p.id).slice(0,80),p]));
  for(const photo of photos){const pairing=sourcePhotos.get(photo.id)?.pairing;if(pairing&&typeof pairing==='object')photo.pairing={place:typeof pairing.place==='string'?pairing.place.trim().slice(0,100):'',person:['a','b'].includes(pairing.person)?pairing.person:''};}
  const items = (Array.isArray(s.items) ? s.items : []).filter(i => i && ids.has(i.photoId)).slice(0, 5000).map(i => ({ id: String(i.id).slice(0,80), photoId: i.photoId, x: finite(i.x, 0, -1e6, 1e6), y: finite(i.y, 0, -1e6, 1e6), width: finite(i.width, 240, i.layoutSizing==='viewport'?1e-9:i.presentation==='print'?.001:60, 2400), angle: finite(i.angle, 0, -36000, 36000), mount: i.mount === 'slide' ? 'slide' : 'bare', sprockets:i.sprockets!==false, presentation:i.presentation==='print'?'print':'film',layoutSizing:i.layoutSizing==='viewport'?'viewport':'free', group: typeof i.group === 'string' ? i.group.slice(0,80) : null }));
  const heroIds=new Set((Array.isArray(s.items)?s.items:[]).filter(i=>i?.hero===true).map(i=>String(i.id).slice(0,80)));
  for(const item of items)item.hero=heroIds.has(item.id);
  const itemIds=new Set(items.map(i=>i.id)),claimed=new Set();
  const editorialPages=(Array.isArray(s.editorialPages)?s.editorialPages:[]).slice(0,5000).filter(p=>p&&typeof p==='object').map((p,k)=>({
    x:finite(p.x,0,-1e6,1e6),y:finite(p.y,0,-1e6,1e6),width:finite(p.width,1000,100,2400),height:finite(p.height,1000*1200/849,p.kind==='viewport'?1e-6:100,p.kind==='viewport'?1e6:4000),number:Math.round(finite(p.number,k+1,1,10000)),kind:['viewport','moments','diptych'].includes(p.kind)?p.kind:'magazine',
    ...(p.kind==='diptych'?{background:'#ffffff',pairReason:typeof p.pairReason==='string'?p.pairReason.slice(0,80):'manual'}:{}),
    composition:typeof p.composition==='string'?p.composition.slice(0,40):'legacy',variant:Math.round(finite(p.variant,0,0,1000000)),seed:Math.round(finite(p.seed,0,0,4294967295)),
    role:['opening','story','pause','closing'].includes(p.role)?p.role:'story',heroId:typeof p.heroId==='string'&&Array.isArray(p.itemIds)&&p.itemIds.includes(p.heroId)&&itemIds.has(p.heroId)?p.heroId:null,
    ...(p.grid?.version===1?{grid:{version:1,columns:12,subdivisions:Math.round(finite(p.grid.subdivisions,1,1,1024))}}:{}),
    itemIds:(Array.isArray(p.itemIds)?p.itemIds:[]).filter(id=>{if(!itemIds.has(id)||claimed.has(id))return false;claimed.add(id);return true;})
  })).filter(p=>p.kind==='diptych'?p.itemIds.length===2:p.itemIds.length);
  const sourceItems=new Map((Array.isArray(s.items)?s.items:[]).filter(Boolean).map(i=>[String(i.id).slice(0,80),i]));
  const cleanItems=new Map(items.map(i=>[i.id,i]));
  for(const page of editorialPages.filter(p=>p.kind==='diptych')){
    page.height=page.width*1.5;
    const height=(page.height-page.width*.008)/2;
    page.itemIds.forEach((id,k)=>{const item=cleanItems.get(id),crop=sourceItems.get(id)?.crop||{};Object.assign(item,{x:page.x+page.width/2,y:page.y+k*(height+page.width*.008)+height/2,width:page.width,height,angle:0,group:null,presentation:'print',crop:{x:finite(crop.x,.5,0,1),y:finite(crop.y,.5,0,1),zoom:finite(crop.zoom,1,1,4)}});});
  }
  const printedIds=new Set(editorialPages.filter(p=>p.kind!=='viewport').flatMap(p=>p.itemIds));
  for(const item of items)if(printedIds.has(item.id))item.presentation='print';
  return { version: 1, photos, items, editorialPages, editorialRevision:Math.round(finite(s.editorialRevision,0,0,1000000)),momentsRevision:Math.round(finite(s.momentsRevision,0,0,1000000)),viewportRevision:Math.round(finite(s.viewportRevision,0,0,1000000)),diptychMode:['related','color','place','couple','manual'].includes(s.diptychMode)?s.diptychMode:'related', camera: { x: finite(s.camera?.x, 0, -1e6, 1e6), y: finite(s.camera?.y, 0, -1e6, 1e6), zoom: finite(s.camera?.zoom, 1, .05, 8) }, brightness: finite(s.brightness, 1, .2, 1.6), lit: s.lit !== false, transmission: s.transmission !== false, sound: s.sound !== false, layoutStyle:['editorial','moments','viewport','grid','contact','diptych'].includes(s.layoutStyle)?s.layoutStyle:'editorial', mount: s.mount === 'slide' ? 'slide' : 'bare', closeMode: s.closeMode === '8' ? '8' : 'original' };
}
module.exports = { supported, cleanState, finite };

