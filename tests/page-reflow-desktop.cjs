const {_electron}=require('playwright');
const fs=require('node:fs/promises'),fsSync=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),version=require('../package.json').version;
const out=process.env.DOSE_VERIFY_OUTPUT||path.resolve(root,'../../outputs/v'+version+'/verification');
const work=path.join(__dirname,'results','page-reflow-'+Date.now()),profile=path.join(work,'profile');
const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
const wait=ms=>new Promise(r=>setTimeout(r,ms)),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const clone=v=>JSON.parse(JSON.stringify(v));
(async()=>{await fs.mkdir(out,{recursive:true});await fs.mkdir(work,{recursive:true});
 const files=[],hashes=[];const src=['01-valley.jpg','02-river.jpg','03-cliff.jpg','04-waterfall.jpg','05-landscape.jpg','06-castle.jpg'];
 for(let n=0;n<24;n++){const f=path.join(work,String(n+1).padStart(2,'0')+'.jpg');await sharp(path.join(__dirname,'fixtures',src[n%src.length])).resize(900,[600,900,1200][n%3],{fit:'cover'}).jpeg({quality:90}).toFile(f);files.push(f);hashes.push(sha(await fs.readFile(f)));}
 let app,page;const errors=[],checks=[];
 async function start(){app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});page=await app.firstWindow();await app.evaluate(({BrowserWindow})=>{const w=BrowserWindow.getAllWindows()[0];w.webContents.setBackgroundThrottling(false);w.hide();w.setSize(1400,1000);});page.on('pageerror',e=>errors.push(e.message));await page.waitForSelector('#import');}
 async function saved(){await wait(700);return (await page.evaluate(()=>window.lighttable.load())).state;}
 async function importFiles(fsx){await app.evaluate(({dialog},f)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:f});},fsx);await page.click('#import');await page.waitForFunction(()=>!document.querySelector('#import').disabled,null,{timeout:120000});if(await page.locator('#toast button').isVisible())await page.locator('#toast button').click();}
 function pageSig(s,p){return {id:p.id,x:p.x,y:p.y,width:p.width,height:p.height,number:p.number,kind:p.kind,composition:p.composition,variant:p.variant,itemIds:[...p.itemIds],items:p.itemIds.map(id=>{const i=s.items.find(x=>x.id===id);return {id,x:i.x,y:i.y,width:i.width,height:i.height,number:i.number,kind:i.kind,itemIds:i.itemIds};})};}

 function assertLocal(before,after,index){
  const a=before.editorialPages[index],b=after.editorialPages[index],paper=p=>{const{composition,variant,seed,...rest}=p;return rest;};
  assert.deepEqual(paper(b),paper(a),'paper, membership and ordering must stay exact');assert.notEqual(b.composition,a.composition);assert.equal(b.variant,a.variant+1);
  assert.deepEqual(after.editorialPages.filter((_,i)=>i!==index),before.editorialPages.filter((_,i)=>i!==index),'every other page must stay byte-equivalent');
  const ids=new Set(a.itemIds);assert.deepEqual(after.items.filter(i=>!ids.has(i.id)),before.items.filter(i=>!ids.has(i.id)));
  for(const id of ids){const p=before.items.find(i=>i.id===id),q=after.items.find(i=>i.id===id);assert(p.x!==q.x||p.y!==q.y||p.width!==q.width,'each page member participates');}
  assert.deepEqual(after.photos,before.photos);assert.deepEqual(after.camera,before.camera);assert.equal(after.layoutStyle,before.layoutStyle);
  for(const key of ['editorialRevision','momentsRevision','viewportRevision'])assert.equal(after[key],before[key]);
 }
 async function selectIds(ids){
  const s=await saved(),first=s.items.find(i=>i.id===ids[0]);await page.locator('.film-thumb[data-id="'+first.photoId+'"]').click();
  for(const id of ids.slice(1)){const current=await saved(),i=current.items.find(i=>i.id===id),r=await page.locator('#table').boundingBox();await page.keyboard.down('Control');await page.mouse.click(r.x+r.width/2+current.camera.x+i.x*current.camera.zoom,r.y+r.height/2+current.camera.y+i.y*current.camera.zoom);await page.keyboard.up('Control');}
 }
 async function clearSelection(){await page.locator('#table').focus();await page.keyboard.press('Escape');}
 async function assertToolbar(){
  await wait(300);const s=await page.locator('#stage').boundingBox();for(const sel of ['#selection-bar','#reflow-page']){const b=await page.locator(sel).boundingBox();assert(b&&b.x>=s.x&&b.x+b.width<=s.x+s.width&&b.y>=s.y&&b.y+b.height<=s.y+s.height,sel+' must fit inside stage');}
 }


 async function verifyGrid(s){
  const result=await page.evaluate(s=>{
   let maxColumnError=0,maxBaselineError=0,count=0;
   for(const p of s.editorialPages){if(p.grid?.version!==1)throw Error('Missing grid contract');const g=DoseLayout.gridSpec(p.width,p.height,p.grid.subdivisions);
    for(const id of p.itemIds){const i=s.items.find(i=>i.id===id),photo=s.photos.find(p=>p.id===i.photoId),m=DoseFilmFrame.metrics(i.width,i.width*photo.height/photo.width,i.presentation==='print'?'bare':i.mount,i.presentation!=='print'&&i.sprockets!==false);
     const left=i.x-m.ow/2-p.x,right=i.x+m.ow/2-p.x,top=i.y-m.oh/2-p.y,row=(top-g.top)/g.baseline;
     maxColumnError=Math.max(maxColumnError,Math.min(...g.lefts.map(x=>Math.abs(x-left))),Math.min(...g.rights.map(x=>Math.abs(x-right))));
     maxBaselineError=Math.max(maxBaselineError,Math.abs(row-Math.round(row))*g.baseline);count++;
    }
   }
   return {count,maxColumnError,maxBaselineError};
  },s);
  assert.equal(result.count,s.items.length);assert(result.maxColumnError<1e-6&&result.maxBaselineError<1e-6,JSON.stringify(result));return result;
 }
 async function guideShot(s,name){
  await page.evaluate(s=>{
   const stage=document.querySelector('#stage'),c=document.createElement('canvas');c.id='verification-grid';c.width=stage.clientWidth*devicePixelRatio;c.height=stage.clientHeight*devicePixelRatio;c.style.cssText='position:absolute;inset:0;width:100%;height:100%;pointer-events:none';const ctx=c.getContext('2d');ctx.scale(devicePixelRatio,devicePixelRatio);
   for(const p of s.editorialPages){const g=DoseLayout.gridSpec(p.width,p.height,p.grid.subdivisions),z=s.camera.zoom,x=stage.clientWidth/2+s.camera.x+p.x*z,y=stage.clientHeight/2+s.camera.y+p.y*z;ctx.lineWidth=.6;ctx.strokeStyle='rgba(130,43,43,.4)';
    for(let col=0;col<g.lefts.length;col++){ctx.beginPath();ctx.moveTo(x+g.lefts[col]*z,y+g.top*z);ctx.lineTo(x+g.lefts[col]*z,y+(g.top+g.rows*g.baseline)*z);ctx.stroke();ctx.beginPath();ctx.moveTo(x+g.rights[col]*z,y+g.top*z);ctx.lineTo(x+g.rights[col]*z,y+(g.top+g.rows*g.baseline)*z);ctx.stroke();}
    ctx.strokeStyle='rgba(45,76,111,.20)';for(let row=0;row<=g.rows;row+=4*g.subdivisions){ctx.beginPath();ctx.moveTo(x+g.margin*z,y+(g.top+row*g.baseline)*z);ctx.lineTo(x+(p.width-g.margin)*z,y+(g.top+row*g.baseline)*z);ctx.stroke();}
   }stage.append(c);
  },s);await page.screenshot({path:path.join(out,name)});await page.locator('#verification-grid').evaluate(el=>el.remove());
 }

 try{
  await start();await importFiles(files);await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===24,null,{timeout:120000});
  await page.selectOption('#layout-style','editorial');let before=await saved();assert(before.editorialPages.length>=3);const adjustments=clone(before.photos.map(p=>p.adjustments));
  const targetIndex=0,target=before.editorialPages[targetIndex],member=target.itemIds[0],thumb=before.items.find(i=>i.id===member);const thumbIndex=before.photos.findIndex(p=>p.id===thumb.photoId);await page.locator('.film-thumb').nth(thumbIndex).click();
  assert(await page.locator('#reflow-page').isVisible());assert(await page.locator('#reflow-page').isEnabled());
  await verifyGrid(before);await guideShot(before,'grid-guides-before.png');const original=pageSig(before,target),others=before.items.filter(i=>!target.itemIds.includes(i.id)).map(clone);await page.screenshot({path:path.join(out,'page-reflow-before.png')});await page.click('#reflow-page');let after=await saved();
  const changed=pageSig(after,after.editorialPages[targetIndex]);assert.notEqual(changed.composition,original.composition);assert.notEqual(changed.variant,original.variant);assert.deepEqual([...changed.itemIds].sort(),[...original.itemIds].sort());assert.deepEqual({x:changed.x,y:changed.y,width:changed.width,height:changed.height,number:changed.number,kind:changed.kind},{x:original.x,y:original.y,width:original.width,height:original.height,number:original.number,kind:original.kind});assert(original.items.some(o=>{const i=changed.items.find(x=>x.id===o.id);return i.x!==o.x||i.y!==o.y||i.width!==o.width||i.height!==o.height}),'reflow must change target geometry');assert(original.items.every(o=>{const i=changed.items.find(x=>x.id===o.id);return i.x!==o.x||i.y!==o.y||i.width!==o.width||i.height!==o.height}),'all target members must change geometry');for(const o of others)assert.deepEqual(after.items.find(i=>i.id===o.id),o);assert.deepEqual(after.photos.map(p=>p.adjustments),adjustments);assertLocal(before,after,targetIndex);await verifyGrid(after);await guideShot(after,'grid-guides-after.png');checks.push('One selected member reflows every target-page photo; paper/membership, all other pages/items, camera and adjustments remain exact');await page.screenshot({path:path.join(out,'page-reflow-after.png')});
  await page.click('#reflow-page');const repeated=await saved();assert.notEqual(repeated.editorialPages[targetIndex].variant,changed.variant);checks.push('Repeated page reflow advances variant');
  await page.locator('#table').focus();await page.keyboard.press('Control+z');assert.deepEqual(pageSig(await saved(),(await saved()).editorialPages[targetIndex]),changed);await page.keyboard.press('Control+Shift+z');const redo=await saved();assert.equal(redo.editorialPages[targetIndex].variant,repeated.editorialPages[targetIndex].variant);checks.push('Ctrl+Z and Ctrl+Shift+Z restore page reflow');
  const persisted=await saved(),persistSig=pageSig(persisted,persisted.editorialPages[targetIndex]);await app.close();app=null;await start();await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===24,null,{timeout:120000});const restored=await saved();assert.deepEqual(pageSig(restored,restored.editorialPages[targetIndex]),persistSig);checks.push('Restart persists page reflow variant');

  let current=await saved();const p0=current.editorialPages[0],p1=current.editorialPages[1];
  await selectIds([p0.itemIds[0],p1.itemIds[0]]);assert(await page.locator('#reflow-page').isDisabled());assert.equal(await page.locator('#selection-name').textContent(),'已选择 2 张');checks.push('Real Ctrl+canvas cross-page selection disables local reflow');
  await selectIds(p0.itemIds.slice(0,2));assert(await page.locator('#reflow-page').isEnabled());assert.equal(await page.locator('#selection-name').textContent(),'已选择 2 张');const sameBefore=await saved();await page.click('#reflow-page');assertLocal(sameBefore,await saved(),0);checks.push('Same-page multi-selection reflows exactly that one page');
  await clearSelection();await page.selectOption('#layout-style','moments');let moments=await saved();assert.equal(moments.editorialPages.length,9);const mi=4;await selectIds(moments.editorialPages[mi].itemIds.slice(0,2));assert(await page.locator('#reflow-page').isEnabled());const mb=await saved();await page.click('#reflow-page');const ma=await saved();assert.equal(ma.editorialPages.length,9);assertLocal(mb,ma,mi);await verifyGrid(ma);await page.screenshot({path:path.join(out,'page-reflow-moments.png')});checks.push('Middle page in nine-page Moments reflows locally, leaving the other eight pages and all grading exact');
  await clearSelection();await page.selectOption('#layout-style','editorial');current=await saved();await selectIds([current.editorialPages[0].itemIds[0]]);await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(980,680));await page.click('#fit');await assertToolbar();await page.screenshot({path:path.join(out,'page-reflow-compact.png')});await page.click('#film-color');await page.click('#fit');await assertToolbar();await page.screenshot({path:path.join(out,'page-reflow-compact-panel.png')});checks.push('980x680 selection toolbar fits inside the stage, including when the grading panel is open');

  await page.click('#film-panel-close');await clearSelection();await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(1400,1000));const measured=[];for(let v=0;v<6;v++){await page.click('#auto-layout');const s=await saved();measured.push(await verifyGrid(s));await page.screenshot({path:path.join(out,'grid-variant-'+v+'.png')});}checks.push('All six magazine reading paths satisfy actual column-edge and baseline measurements in the packaged app');
  await page.selectOption('#layout-style','viewport');let windowLayout=await saved();measured.push(await verifyGrid(windowLayout));await page.screenshot({path:path.join(out,'grid-viewport-wide.png')});await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(980,680));await page.click('#film-color');windowLayout=await saved();measured.push(await verifyGrid(windowLayout));await page.screenshot({path:path.join(out,'grid-viewport-compact-panel.png')});checks.push('Adaptive window mode remains on the measured grid after resize and opening the grading panel');
  await fs.writeFile(path.join(out,'grid-measurements.json'),JSON.stringify({version,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,measured},null,2));await page.click('#film-panel-close');await clearSelection();await page.selectOption('#layout-style','grid');await page.locator('.film-thumb').first().click();assert(await page.locator('#reflow-page').isHidden());checks.push('Photo grid has no misleading magazine-page reflow action');
  for(let i=0;i<files.length;i++)assert.equal(sha(await fs.readFile(files[i])),hashes[i]);checks.push('Every generated input file retains its original SHA256');assert.deepEqual(errors,[]);const report={version,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,errors,checks};await fs.writeFile(path.join(out,'page-reflow-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
 }catch(e){if(page)await page.screenshot({path:path.join(out,'page-reflow-failure.png')}).catch(()=>{});throw e;}finally{await app?.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
