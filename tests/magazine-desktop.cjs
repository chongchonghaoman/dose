const {_electron}=require('playwright'),fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.env.DOSE_MAGAZINE_OUTPUT||path.join(__dirname,'results/magazine'));
(async()=>{
  await fs.mkdir(out,{recursive:true});const profile=await fs.mkdtemp(path.join(out,'profile-'));
  const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
  const config=process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env};
  let app,page;const errors=[],checks=[];
  const start=async()=>{app=await _electron.launch(config);page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));await page.waitForFunction(()=>document.body.dataset.ready==='true');await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(1600,1060));};
  const saved=async()=>{await page.waitForFunction(()=>document.querySelector('#save-state').dataset.state==='saved');return(await page.evaluate(()=>window.lighttable.load())).state;};
  const shot=async name=>{if(await page.locator('#toast').isVisible())await page.locator('#toast button').click();await page.waitForTimeout(600);await page.screenshot({path:path.join(out,name+'.png')});};
  const select=async(id)=>{const s=await saved(),item=s.items.find(i=>i.id===id),b=await page.locator('#table').boundingBox();await page.mouse.click(b.x+b.width/2+s.camera.x+item.x*s.camera.zoom,b.y+b.height/2+s.camera.y+item.y*s.camera.zoom);};
  const exportPages=async(format)=>{
    const previous=new Set(await fs.readdir(out));
    await app.evaluate(({dialog},folder)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[folder]});},out);
    await page.click('#export-magazine');await page.selectOption('#magazine-format',format);
    await page.selectOption('#magazine-size','3600');await page.click('#magazine-export-start');
    await page.waitForFunction(()=>!document.querySelector('#magazine-open-folder').hidden,null,{timeout:120000});
    await shot(format+'-export');await page.click('#magazine-close');
    const candidates=await Promise.all((await fs.readdir(out)).filter(n=>n.startsWith('dose-magazine-')&&!previous.has(n)).map(async n=>({folder:path.join(out,n),manifest:JSON.parse(await fs.readFile(path.join(out,n,'manifest.json'),'utf8'))})));
    return candidates.find(c=>c.manifest.format===format);
  };
  try{
    await start();
    const inputs=['01-valley.jpg','02-river.jpg','03-cliff.jpg','04-waterfall.jpg','05-landscape.jpg','06-castle.jpg'].map(n=>path.join(__dirname,'fixtures',n));
    await app.evaluate(({dialog},files)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:files});},inputs);
    await page.click('#import');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===6,null,{timeout:60000});
    await page.waitForFunction(()=>[...document.querySelectorAll('.film-thumb img')].every(i=>i.complete&&i.naturalWidth>0));
    await page.evaluate(()=>{window.paperText=[];const fill=CanvasRenderingContext2D.prototype.fillText;CanvasRenderingContext2D.prototype.fillText=function(text,...args){window.paperText.push(String(text));return fill.call(this,text,...args);};});
    await page.click('#auto-layout');let s=await saved();assert(s.editorialPages.length>=3&&s.editorialPages.length<=4);
    assert.equal(new Set(s.editorialPages.flatMap(p=>p.itemIds)).size,6);
    assert(new Set(s.editorialPages.map(p=>p.itemIds.length)).size>1);
    assert(!(await page.evaluate(()=>window.paperText)).some(t=>/VOLUME I|PHOTO JOURNAL/.test(t)));
    await shot('01-book');checks.push('six photos become a paced book with clean paper and no missing or duplicated photos');
    const group=s.editorialPages.find(p=>p.itemIds.length>1),heroId=group.itemIds.at(-1),before=structuredClone(s);
    await select(heroId);await page.click('#set-hero');s=await saved();
    assert(await page.locator('#mount').isHidden());assert(await page.locator('#sprockets').isHidden());
    assert.equal(s.items.find(i=>i.id===heroId).hero,true);
    const current=s.editorialPages.find(p=>p.itemIds.includes(heroId));
    assert.equal(current.heroId,heroId);
    const area=i=>i.width*i.width/(s.photos.find(p=>p.id===i.photoId).width/s.photos.find(p=>p.id===i.photoId).height);
    const hero=s.items.find(i=>i.id===heroId);assert(current.itemIds.filter(id=>id!==heroId).every(id=>area(hero)>area(s.items.find(i=>i.id===id))*1.3));
    await shot('02-hero');
    await page.focus('#table');await page.keyboard.press('Control+z');s=await saved();const ordered=items=>items.slice().sort((a,b)=>a.id.localeCompare(b.id));assert.deepEqual(ordered(s.items),ordered(before.items));
    await page.keyboard.press('Control+Shift+z');s=await saved();assert(s.items.find(i=>i.id===heroId).hero);
    await select(heroId);const others=s.editorialPages.filter(p=>!p.itemIds.includes(heroId));await page.click('#reflow-page');s=await saved();
    assert.deepEqual(s.editorialPages.filter(p=>!p.itemIds.includes(heroId)),others);assert.equal(s.editorialPages.find(p=>p.itemIds.includes(heroId)).heroId,heroId);
    checks.push('hero has a visibly larger area; undo/redo and local reflow retain hero and other pages');
    await page.focus('#table');await page.keyboard.press('Escape');await shot('03-book-with-hero');
    const png=await exportPages('png'),jpg=await exportPages('jpeg');
    assert.equal(png.manifest.pages.length,s.editorialPages.length);assert.equal(jpg.manifest.pages.length,s.editorialPages.length);
    for(const output of [png,jpg])for(const file of output.manifest.pages){
      const meta=await sharp(path.join(output.folder,file.file)).metadata();assert.equal(Math.max(meta.width,meta.height),3600);assert(meta.icc?.length>0);
    }
    const paper=await sharp(path.join(png.folder,png.manifest.pages[0].file)).extract({left:0,top:0,width:1,height:1}).raw().toBuffer();assert.deepEqual([...paper].slice(0,3),[232,230,227]);
    checks.push('real UI exports every page to JPEG and PNG, 3600px long edge, embedded sRGB and clean paper');
    await page.click('#export-magazine');await app.evaluate(({dialog})=>{dialog.showOpenDialog=async()=>({canceled:true,filePaths:[]});});await page.click('#magazine-export-start');
    await page.waitForFunction(()=>document.querySelector('#magazine-status').textContent==='已取消');assert(await page.locator('#magazine-open-folder').isHidden());await page.click('#magazine-close');
    const persisted=await saved();await app.close();app=null;await start();s=await saved();assert.deepEqual(s.items,persisted.items);assert.deepEqual(s.editorialPages,persisted.editorialPages);
    await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(1000,720));await page.click('#fit');await shot('04-small-window');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.click('#export-magazine');await shot('05-small-export');await page.keyboard.press('Escape');
    assert(await page.locator('#magazine-dialog').evaluate(e=>!e.open));
    checks.push('cancel, restart persistence, 1000px desktop layout and dialog keyboard dismissal');
    assert.deepEqual(errors,[]);
    await fs.writeFile(path.join(out,'verification.json'),JSON.stringify({passed:true,version:'0.29.0',packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,errors,pages:s.editorialPages,png:png.folder,jpeg:jpg.folder},null,2));
    console.log(JSON.stringify({passed:true,checks,output:out,png:png.folder,jpeg:jpg.folder}));
  }catch(e){await page?.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw e;}
  finally{await app?.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
