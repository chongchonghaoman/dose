const {_electron}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.env.DOSE_LUT_OUTPUT||path.join(__dirname,'results/lut-panel'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
(async()=>{
  await fs.mkdir(out,{recursive:true});
  const profile=await fs.mkdtemp(path.join(out,'profile-')),env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
  const inputs=['01-valley.jpg','02-river.jpg'].map(n=>path.join(__dirname,'fixtures',n)),hashes=await Promise.all(inputs.map(async f=>sha(await fs.readFile(f))));
  const config=process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env};
  let app,page;const errors=[],checks=[],layouts=[];
  const start=async()=>{app=await _electron.launch(config);page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));await page.waitForFunction(()=>document.body.dataset.ready==='true');};
  const saved=async()=>{await page.waitForFunction(()=>document.querySelector('#save-state').dataset.state==='saved');return (await page.evaluate(()=>window.lighttable.load())).state;};
  const slider=async(id,value)=>{await page.locator(id).evaluate((el,v)=>{el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));},String(value));await saved();};
  try{
    await start();await app.evaluate(({dialog},files)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:files});},inputs);
    await page.click('#import');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===2);
    await page.focus('#table');await page.keyboard.press('Control+a');await page.keyboard.press('Delete');await saved();
    await page.locator('.film-thumb').first().click();await page.click('#film-color');
    assert.equal(await page.locator('#film-engine,#spectral-controls,#auto-fit-mode').count(),0);
    assert(await page.locator('#lut-library').isEnabled());
    assert.equal((await saved()).items.length,0,'selecting a library photo must not place it');
    assert.equal(await page.locator('.film-thumb').first().getAttribute('aria-pressed'),'true');
    const lut=await page.locator('#lut-library option').evaluateAll(os=>os.find(o=>o.value&&!o.value.startsWith('__')&&!o.disabled)?.value);
    assert(lut,'installed LUT library must be usable');await page.selectOption('#lut-library',lut);
    let state=await saved();assert.equal(state.photos[0].adjustments.lutId,lut);assert.equal(state.photos[1].adjustments.lut,false);
    checks.push('unplaced photo selection and isolated LUT application');
    await page.click('#photo-back');await page.click('#loupe');await page.locator('#table').click({position:{x:100,y:100}});
    assert.equal(await page.locator('.film-thumb').first().getAttribute('aria-pressed'),'true');
    await page.click('#pointer');
    await page.locator('.film-thumb').nth(1).click({modifiers:['Control']});assert.equal(await page.locator('#film-scope').textContent(),'2 张照片');
    assert.equal(await page.locator('#lut-library').inputValue(),'__mixed');
    await page.selectOption('#lut-library',lut);await slider('#film-exposure',.4);await slider('#lut-strength',35);
    state=await saved();assert(state.photos.every(p=>p.adjustments.engine==='lut'&&p.adjustments.lutId===lut&&p.adjustments.exposure===.4&&p.adjustments.strength===35));
    checks.push('multi-select mixed style and shared slider edits');
    await app.evaluate(({dialog},out)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[out]});},out);
    await page.selectOption('#export-format','png');await page.click('#export-photos');
    await page.waitForFunction(()=>document.querySelector('#export-photos').textContent==='导出照片',null,{timeout:120000});
    const folder=(await fs.readdir(out)).find(f=>f.startsWith('LightTable-'));assert(folder);
    const exports=(await fs.readdir(path.join(out,folder))).filter(n=>n.endsWith('.png'));assert.equal(exports.length,2);
    const exported=path.join(out,folder,exports.find(n=>n.includes('valley'))||exports[0]),meta=await sharp(exported).metadata();assert.equal(meta.format,'png');assert(meta.icc?.length>0);
    const a=await sharp(inputs[0]).resize(64,64,{fit:'fill'}).removeAlpha().raw().toBuffer(),b=await sharp(exported).resize(64,64,{fit:'fill'}).removeAlpha().raw().toBuffer();
    const diff=a.reduce((sum,v,i)=>sum+Math.abs(v-b[i]),0)/a.length;assert(diff>1,'LUT/exposure export must change real pixels');
    checks.push('two PNG exports contain adjusted pixels and embedded ICC');
    await page.focus('#film-color');await page.keyboard.press('Escape');assert(await page.locator('#film-panel').isHidden());
    await page.click('#auto-layout');await page.locator('.film-thumb').first().click();await page.click('#film-color');
    for(const size of [[1440,960],[980,680]]){
      await app.evaluate(({BrowserWindow},s)=>BrowserWindow.getAllWindows()[0].setSize(...s),size);await page.waitForTimeout(300);
      await page.screenshot({path:path.join(out,'panel-'+size[0]+'.png')});
      const layout=await page.evaluate(()=>({width:innerWidth,panel:document.querySelector('#film-panel').getBoundingClientRect().toJSON(),footer:document.querySelector('.film-export-row').getBoundingClientRect().toJSON()}));assert(layout.footer.bottom<=layout.panel.bottom);layouts.push(layout);
    }
    if(await page.locator('#photo-back').isVisible())await page.click('#photo-back');await page.click('#loupe');
    const tools=await page.locator('.tools').boundingBox(),bar=await page.locator('.topbar').evaluate(el=>({width:el.clientWidth,pad:parseFloat(getComputedStyle(el).paddingRight)}));
    assert(tools.x+tools.width<=bar.width-bar.pad+2,'loupe controls must not enter Windows titlebar buttons');
    await page.screenshot({path:path.join(out,'loupe-small.png')});
    await page.click('#pointer');await page.locator('.film-panel-scroll').evaluate(el=>el.scrollTop=el.scrollHeight);
    await page.locator('#texture-section summary').click();await page.locator('.film-panel-scroll').evaluate(el=>el.scrollTop=el.scrollHeight);await page.screenshot({path:path.join(out,'texture-small.png')});
    checks.push('1440 and 980 desktop layouts, loupe toolbar and fixed export footer; Escape closes inspector');
    // Saved old recipes remain readable. Switching to a LUT is explicit and undoable.
    state=await saved();await app.close();app=null;
    const film=require('../src/film-engine.js');const legacy={...film.SPECTRAL_DEFAULTS,exposure:.7,shadows:12,grain:0,halation:0,bloom:0,autoFitMode:'off'};
    state.photos[0].adjustments=legacy;state.photos[1].adjustments={...film.DEFAULTS,lut:true,lutId:'a'.repeat(64)};
    await fs.writeFile(path.join(profile,'table.json'),JSON.stringify(state));
    await start();await page.locator('.film-thumb').first().click();await page.click('#film-color');
    assert.equal(await page.locator('#lut-library').inputValue(),'__legacy');assert(await page.locator('#film-exposure').isDisabled());
    assert.equal((await saved()).photos[0].adjustments.exposure,.7);
    await page.selectOption('#lut-library',lut);await saved();await page.focus('#lut-library');await page.keyboard.press('Control+z');state=await saved();
    assert.equal(state.photos[0].adjustments.engine,'spectral');assert.equal(state.photos[0].adjustments.exposure,.7);assert.equal(state.photos[0].adjustments.shadows,12);
    await page.locator('.film-thumb').nth(1).click();assert(await page.locator('#lut-error').isVisible());assert.equal(await page.locator('#lut-library').inputValue(),'a'.repeat(64));
    await page.selectOption('#lut-library',lut);assert(await page.locator('#lut-error').isHidden());await saved();
    checks.push('legacy recipe preserved on open and restored by undo; missing LUT displayed and replaceable');
    assert.deepEqual(await Promise.all(inputs.map(async f=>sha(await fs.readFile(f)))),hashes);assert.deepEqual(errors,[]);
    await fs.writeFile(path.join(out,'verification.json'),JSON.stringify({passed:true,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,layouts,png:{width:meta.width,height:meta.height,iccBytes:meta.icc.length,meanPixelDifference:diff},errors},null,2));
    console.log('LUT desktop checks passed',out);
  }catch(e){await page?.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw e;}
  finally{await app?.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
