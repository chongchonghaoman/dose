// Opt-in read-only reproduction of the current library; both apps use COPIES
// of its document and LUT directory in isolated test profiles.
const {_electron}=require('playwright'),fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),sharp=require('sharp'),{layoutSquare,metricsOf}=require('../src/share-layout.js');
const root=path.resolve(__dirname,'..'),version=require('../package.json').version,out=path.resolve(root,'../../outputs/v'+version+'/verification'),work=path.join(__dirname,'results/density-gallery-'+Date.now()),source=process.env.DOSE_DENSITY_SOURCE;
const wait=ms=>new Promise(r=>setTimeout(r,ms)),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
async function capture(executable,label,bytes,photos){
 const profile=path.join(work,label+'-profile');await fs.mkdir(profile,{recursive:true});await fs.writeFile(path.join(profile,'table.json'),bytes);
 try{await fs.cp(path.join(source,'luts'),path.join(profile,'luts'),{recursive:true});}catch(e){if(e.code!=='ENOENT')throw e;}
 const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;let app,page;const errors=[],badResponses=[],validIds=new Set(photos.map(p=>p.id)),documentPhotoCount=JSON.parse(bytes.toString('utf8')).photos.length;
 try{
  app=await _electron.launch({executablePath:executable,args:[],env});page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.url().startsWith('photo:')&&r.status()>=400&&validIds.has(new URL(r.url()).hostname))badResponses.push(r.status());});
  await app.evaluate(({BrowserWindow})=>{const w=BrowserWindow.getAllWindows()[0];w.webContents.setBackgroundThrottling(false);w.hide();w.setSize(1400,1000);});
  await page.waitForFunction(n=>document.querySelectorAll('.film-thumb').length===n,documentPhotoCount,{timeout:120000});await wait(1000);
  if(await page.locator('#toast button').isVisible())await page.locator('#toast button').click();const before=(await page.evaluate(()=>window.lighttable.load())).state;
  await page.click('#share-grid');await page.selectOption('#share-layout','editorial');await page.waitForFunction(n=>+document.querySelector('#share-canvas')?.dataset.cached>=n,photos.length,{timeout:240000});await wait(350);
  for(const [id,value]of [['share-mag',1.5],['share-lens',14]])await page.locator('#'+id).evaluate((el,v)=>{el.value=String(v);el.dispatchEvent(new Event('input',{bubbles:true}));},value);
  const c=await page.locator('#share-canvas').boundingBox(),p=await page.locator('#share-canvas').evaluate(el=>({x:+el.dataset.lensX,y:+el.dataset.lensY}));await page.mouse.move(c.x+p.x/2400*c.width,c.y+p.y/2400*c.height);await page.mouse.down();await page.mouse.move(c.x+c.width/2,c.y+c.height/2,{steps:8});await page.mouse.up();await wait(700);
  const layout=await page.locator('#share-canvas').evaluate(el=>JSON.parse(el.dataset.layout));assert.equal(layout.items.length,photos.length);
  if(label==='after'&&documentPhotoCount>photos.length){assert(await page.locator('#share-missing').isVisible());assert((await page.locator('#share-missing').textContent()).includes(String(documentPhotoCount-photos.length)));}
  await page.screenshot({path:path.join(out,'gallery-'+label+'-ui.png')});await page.locator('#share-canvas').screenshot({path:path.join(out,'gallery-'+label+'-canvas.png')});
  const metrics=metricsOf(layout.items,photos,2400);
  if(label==='after'){
   for(const style of ['moments','viewport','grid','contact']){await page.selectOption('#share-layout',style);await page.waitForTimeout(400);await page.waitForFunction(n=>+document.querySelector('#share-canvas').dataset.cached>=n,photos.length,{timeout:120000});await page.locator('#share-canvas').screenshot({path:path.join(out,'gallery-after-'+style+'.png')});}
   await page.selectOption('#share-layout','editorial');const parent=path.join(work,'actual-export');await fs.mkdir(parent,{recursive:true});await app.evaluate(({dialog},parent)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[parent]});},parent);await page.click('#share-export');await page.waitForSelector('#share-open-folder',{state:'visible',timeout:240000});
   const dirs=await fs.readdir(parent);assert.equal(dirs.length,1);const files=await fs.readdir(path.join(parent,dirs[0]));files.sort();assert.deepEqual(files,Array.from({length:9},(_,i)=>String(i+1).padStart(2,'0')+'.jpg'));
   const parts=[];for(const [i,file]of files.entries()){const f=path.join(parent,dirs[0],file),m=await sharp(f).metadata();assert.equal(m.width,1440);assert.equal(m.height,1440);assert(m.icc);parts.push({input:await sharp(f).resize(360,360).png().toBuffer(),left:i%3*360,top:Math.floor(i/3)*360});}
   await sharp({create:{width:1080,height:1080,channels:3,background:'#e8e6e3'}}).composite(parts).png().toFile(path.join(out,'gallery-after-export-joined.png'));
  }
  await page.click('#share-close');await wait(700);assert.deepEqual((await page.evaluate(()=>window.lighttable.load())).state,before);assert.deepEqual(errors,[]);assert.deepEqual(badResponses,[]);
  return {metrics,errors,failedPhotoResponses:badResponses.length,sourceCount:photos.length};
 }catch(e){if(page)await page.screenshot({path:path.join(out,'gallery-'+label+'-failure.png')}).catch(()=>{});throw e;}finally{await app?.close();}
}
(async()=>{
 if(!source)throw Error('Set DOSE_DENSITY_SOURCE to the existing dose data directory; it will only be read');
 await fs.mkdir(out,{recursive:true});await fs.mkdir(work,{recursive:true});const statePath=path.join(source,'table.json'),bytes=await fs.readFile(statePath),state=JSON.parse(bytes),sourceSha=sha(bytes);
 const readable=await Promise.all(state.photos.map(p=>fs.access(p.path).then(()=>true,()=>false))),availablePhotos=state.photos.filter((_,i)=>readable[i]);assert(availablePhotos.length>0);
 const reference=structuredClone(state);reference.photos=availablePhotos;
 const before=await capture(path.resolve(root,'../../outputs/v0.22.0/dose-win32-x64/dose.exe'),'before',Buffer.from(JSON.stringify(reference)),availablePhotos);
 const after=await capture(process.env.LIGHTTABLE_EXECUTABLE||path.resolve(root,'../../outputs/v'+version+'/dose-win32-x64/dose.exe'),'after',bytes,availablePhotos);
 const variants=[];for(const style of ['editorial','moments','viewport','grid','contact'])for(let variant=0;variant<6;variant++){
  const r=layoutSquare(state.photos,{style,variant}),m=r.metrics;assert.equal(new Set(r.items.map(i=>i.photoId)).size,state.photos.length);assert(m.coverage>=.73&&Math.min(...m.tileCoverage)>=.64&&m.tileSpread<=.23&&m.maxToMedianArea<=3);variants.push({style,variant,...m});
 }
 assert(after.metrics.coverage>before.metrics.coverage*1.4);assert(after.metrics.medianArea>before.metrics.medianArea*1.8);assert(after.metrics.maxToMedianArea<=3);
 const sourceStateUnchanged=sha(await fs.readFile(statePath))===sourceSha;
 const beforeImage=await sharp(path.join(out,'gallery-before-canvas.png')).resize(720,720).png().toBuffer(),afterImage=await sharp(path.join(out,'gallery-after-canvas.png')).resize(720,720).png().toBuffer();
 await sharp({create:{width:1456,height:720,channels:3,background:'#171918'}}).composite([{input:beforeImage,left:0,top:0},{input:afterImage,left:736,top:0}]).png().toFile(path.join(out,'gallery-density-comparison.png'));
 const report={version,packaged:true,photos:state.photos.length,visualComparisonPhotos:availablePhotos.length,unavailableOriginals:state.photos.length-availablePhotos.length,before,after,variants,sourceStateSha256:sourceSha,sourceStateUnchanged,usedIsolatedProfiles:true,originalProfileWasNotLaunched:true,errors:[]};
 await fs.writeFile(path.join(out,'share-density-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({photos:report.photos,before:before.metrics,after:after.metrics,sourceStateUnchanged},null,2));
})().catch(e=>{console.error(e);process.exitCode=1;});
