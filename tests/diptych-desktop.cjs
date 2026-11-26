const {_electron}=require('playwright'),fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.env.DOSE_DIPTYCH_OUTPUT||path.join(__dirname,'results/diptych'));
(async()=>{
  await fs.mkdir(out,{recursive:true});const profile=await fs.mkdtemp(path.join(out,'profile-'));
  const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
  const config=process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env};
  let app,page;const errors=[],checks=[];
  const start=async()=>{app=await _electron.launch(config);page=await app.firstWindow();page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));await page.waitForFunction(()=>document.body.dataset.ready==='true');await app.evaluate(({BrowserWindow})=>{const win=BrowserWindow.getAllWindows()[0];win.webContents.setBackgroundThrottling(false);win.setTitle('dose · 双拼测试');win.setSize(1600,1060);win.showInactive();});};
  const saved=async()=>{await page.waitForFunction(()=>document.querySelector('#save-state').dataset.state==='saved');return(await page.evaluate(()=>window.lighttable.load())).state;};
  const settled=async()=>{await page.waitForFunction(()=>!document.querySelector('.diptych-dialog [data-status]').textContent.includes('正在'),null,{timeout:90000});};
  const shot=async name=>{if(!await page.locator('dialog[open]').count()&&await page.locator('#toast').isVisible())await page.locator('#toast button').click();await page.waitForTimeout(250);await page.screenshot({path:path.join(out,name+'.png')});};
  const select=async id=>{const s=await saved(),item=s.items.find(i=>i.id===id),b=await page.locator('#table').boundingBox();const pt={x:b.x+b.width/2+s.camera.x+item.x*s.camera.zoom,y:b.y+b.height/2+s.camera.y+item.y*s.camera.zoom};await page.mouse.click(pt.x,pt.y);return pt;};
  try{
    await start();console.log('started');const photosDir=process.env.DOSE_DEMO_PHOTOS||path.resolve(root,'../dose-portfolio-demo/photos');
    const inputs=['01-nara.jpg','02-commute.jpg','03-sakura.jpg','04-railway.jpg','05-izakaya.jpg','06-street.jpg'].map(n=>path.join(photosDir,n));
    await app.evaluate(({dialog},files)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:files});},inputs);
    await page.click('#import');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===6,null,{timeout:90000});await saved();
    console.log('imported');await page.selectOption('#layout-style','diptych');await settled();await shot('01-auto-pairing');
    const dialog=page.locator('.diptych-dialog');
    await dialog.locator('[data-mode]').selectOption('manual');await dialog.locator('[data-none]').click();await settled();assert(await dialog.locator('[data-apply]').isDisabled());
    const boxes=dialog.locator('[data-select]');await boxes.nth(3).check();await boxes.nth(1).check();await boxes.nth(4).check();await settled();
    assert.equal(await dialog.locator('.diptych-page').count(),1);assert.match(await dialog.locator('[data-unpaired]').textContent(),/未配对 1/);
    const expectedTop=await boxes.nth(3).getAttribute('data-select');assert((await dialog.locator('.diptych-paper img').first().getAttribute('src')).includes(expectedTop));
    await dialog.locator('[data-swap]').first().click();const expectedBottom=await boxes.nth(1).getAttribute('data-select');assert((await dialog.locator('.diptych-paper img').first().getAttribute('src')).includes(expectedBottom));
    await dialog.locator('[data-all]').click();await settled();checks.push('manual selection order, odd leftover, preview swap and clear/all controls');
    await dialog.locator('[data-mode]').selectOption('place');await settled();
    assert(await dialog.locator('[data-apply]').isDisabled());assert.match(await dialog.locator('[data-unpaired]').textContent(),/GPS|地点/);
    const places=dialog.locator('[data-field="place"]');for(let i=0;i<6;i++)await places.nth(i).fill(i<2?'宇治':i<4?'京都':'奈良');await settled();
    assert.equal(await dialog.locator('.diptych-page').count(),3);await shot('02-place');
    await dialog.locator('[data-mode]').selectOption('couple');await settled();assert(await dialog.locator('[data-apply]').isDisabled());
    const persons=dialog.locator('[data-field="person"]');for(let i=0;i<6;i++)await persons.nth(i).selectOption(i%2?'b':'a');await settled();
    assert.equal(await dialog.locator('.diptych-page').count(),3);await shot('03-person-groups');
    await dialog.locator('[data-apply]').click();let s=await saved();assert.equal(s.editorialPages.length,3);assert(s.items.every(i=>i.crop&&i.height));
    for(const p of s.editorialPages){assert.equal(p.width/p.height,2/3);const members=p.itemIds.map(id=>s.photos.find(p=>p.id===s.items.find(i=>i.id===id).photoId));assert.deepEqual(members.map(p=>p.pairing.person),['a','b']);}
    checks.push('automatic preview, absent-GPS state, manual place annotations, explicit A+B pairing persisted');
    const id=s.editorialPages[0].itemIds[0];await select(id);await page.click('#scale-up');const pt=await select(id);
    await page.mouse.move(pt.x,pt.y);await page.mouse.down();await page.mouse.move(pt.x+28,pt.y+18,{steps:6});await page.mouse.up();s=await saved();
    const crop={...s.items.find(i=>i.id===id).crop},firstOrder=s.editorialPages[0].itemIds.slice();assert(crop.zoom>1);assert(crop.x!==.5||crop.y!==.5);
    await page.click('#swap-diptych');s=await saved();assert.deepEqual(s.editorialPages[0].itemIds,firstOrder.slice().reverse());assert.deepEqual(s.items.find(i=>i.id===id).crop,crop);
    await page.focus('#table');await page.keyboard.press('Control+z');s=await saved();assert.deepEqual(s.editorialPages[0].itemIds,firstOrder);
    await page.keyboard.press('Control+Shift+z');s=await saved();assert.deepEqual(s.editorialPages[0].itemIds,firstOrder.slice().reverse());
    await page.keyboard.press('Escape');await shot('04-diptych-pages');
    checks.push('on-canvas pan/zoom, swap keeps photo crop, undo/redo');
    const exports=[];
    for(const format of ['jpeg','png']){
      const before=new Set(await fs.readdir(out));await app.evaluate(({dialog},folder)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[folder]});},out);
      await page.click('#export-magazine');await page.selectOption('#magazine-format',format);await page.click('#magazine-export-start');
      await page.waitForFunction(()=>!document.querySelector('#magazine-open-folder').hidden,null,{timeout:120000});await shot('05-export-'+format);await page.click('#magazine-close');
      const folder=(await fs.readdir(out)).find(n=>n.startsWith('dose-magazine-')&&!before.has(n));assert(folder);
      const target=path.join(out,folder),manifest=JSON.parse(await fs.readFile(path.join(target,'manifest.json'),'utf8'));assert.equal(manifest.pages.length,3);
      for(const p of manifest.pages){const m=await sharp(path.join(target,p.file)).metadata();assert.equal(m.width,2400);assert.equal(m.height,3600);assert(m.icc?.length>0);}
      exports.push({format,folder:target});
    }
    checks.push('actual UI exports all JPEG and PNG pages at 2400x3600 with sRGB');
    const beforeRestart=await saved();await app.close();app=null;await start();s=await saved();assert.deepEqual(s.items,beforeRestart.items);assert.deepEqual(s.editorialPages,beforeRestart.editorialPages);assert.deepEqual(s.photos.map(p=>p.pairing),beforeRestart.photos.map(p=>p.pairing));
    await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(1000,720));await page.click('#fit');await shot('06-small-window');
    await page.click('#auto-layout');await settled();
    // Last successful mode was couple. Existing labels are restored.
    const current=page.locator('.diptych-dialog');assert.equal(await current.locator('[data-mode]').inputValue(),'couple');
    assert.equal(await current.locator('[data-field="person"]').first().inputValue(),'a');await shot('07-small-composer');
    await page.keyboard.press('Escape');assert(!await current.evaluate(d=>d.open));
    checks.push('restart keeps pairing labels and crop; 1000px window and keyboard dismissal');
    assert.deepEqual(errors,[]);await fs.writeFile(path.join(out,'verification.json'),JSON.stringify({passed:true,version:require('../package.json').version,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,exports,profile},null,2));
    console.log(JSON.stringify({passed:true,checks,exports,out}));
  }catch(error){await page?.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}
  finally{await app?.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
