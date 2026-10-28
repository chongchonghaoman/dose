const {_electron,expect}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.env.DOSE_REFERENCE_OUTPUT||path.join(__dirname,'results/reference'));
const sha=data=>crypto.createHash('sha256').update(data).digest('hex');
(async()=>{
  await fs.mkdir(out,{recursive:true});const profile=await fs.mkdtemp(path.join(out,'profile-'));
  const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
  const input=path.resolve(process.env.DOSE_REFERENCE_INPUT||path.join(__dirname,'fixtures/01-valley.jpg')),originalHash=sha(await fs.readFile(input));
  const config=process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env};
  let app;let editor;const errors=[];let result;
  try{
    app=await _electron.launch(config);const page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));
    await page.waitForFunction(()=>document.body.dataset.ready==='true');
    await app.evaluate(({dialog},input)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[input]});},input);
    await page.click('#import');await page.locator('.film-thumb').first().waitFor();await page.locator('.film-thumb').first().dblclick();
    await page.locator('.film-thumb').first().click();
    await page.click('#reference-editor');editor=await app.waitForEvent('window');editor.on('pageerror',e=>errors.push(e.message));
    await editor.waitForURL('dose-editor://app/index.html');
    await editor.getByTestId('film-list').waitFor({timeout:90000});
    await editor.waitForFunction(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent==='完成并返回 dose');return b&&!b.disabled;},{},{timeout:120000});
    await editor.waitForTimeout(1800);
    await editor.screenshot({path:path.join(out,'01-original-editor.png')});
    await fs.writeFile(path.join(out,'editor-dom.txt'),await editor.locator('body').innerText());
    const state=await editor.evaluate(()=>window.doseEditor.invoke('state',[]));assert.equal(state.hello.backend.available,true);assert(state.hello.methods.includes('write_image'));
    await editor.locator('[data-stock="kodak_tri_x_400"]').click();
    assert(await editor.getByTestId('paper-list').getByText('负片直出',{exact:true}).count());
    if(process.env.DOSE_REFERENCE_EXTENDED){
      await editor.locator('[data-section="filmEdge"]').getByRole('switch').click();
      await editor.getByRole('tab',{name:'显影后',exact:true}).click();
      const exposure=editor.getByTestId('adj-exposure').locator('input');await exposure.fill('0.35');await exposure.press('Enter');
    }
    await editor.waitForFunction(()=>!document.querySelector('.dose-toolbar button').disabled,{},{timeout:120000});
    await editor.waitForTimeout(1200);await editor.screenshot({path:path.join(out,'02-tri-x-editor.png')});
    await editor.getByRole('button',{name:'完成并返回 dose',exact:true}).click();
    await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===2,{},{timeout:180000});
    await page.waitForTimeout(1200);await page.screenshot({path:path.join(out,'03-returned-to-dose.png')});
    result=await page.evaluate(()=>window.lighttable.load());
    assert.equal(result.state.photos.length,2);const original=result.state.photos.find(p=>p.path===input),developed=result.state.photos.find(p=>p.path!==input);assert(original);assert(developed);
    assert(result.state.items.every(i=>i.photoId===developed.id));assert.notEqual(developed.adjustments?.engine,'spectral');
    const metadata=await sharp(developed.path).metadata();assert.equal(metadata.format,'tiff');assert.equal(metadata.depth,'ushort');assert.equal(metadata.bitsPerSample,16);assert(metadata.icc?.length>0);
    const sidecars=await fs.readdir(path.join(profile,'reference-editor','sidecars'));assert(sidecars.length>0);
    const sidecar=JSON.parse(await fs.readFile(path.join(profile,'reference-editor','sidecars',sidecars[0]),'utf8'));assert.equal(sidecar.params.filmStock,'kodak_tri_x_400');assert.equal(sidecar.params.autoExposure,true);assert.equal(sidecar.params.sceneLatitude.active,false);
    if(process.env.DOSE_REFERENCE_EXTENDED){assert.equal(developed.nativeFrame,true);assert.equal(sidecar.adjustments.exposure,.35);assert.equal(sidecar.params.filmEdge.active,true);}
    assert.equal(developed.referenceDeveloped,true);
    assert.equal(await page.locator('.film-thumb[aria-pressed="true"]').getAttribute('data-id'),developed.id,'return must select the new derivative for further adjustment/export');
    await app.evaluate(({dialog},out)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[out]});},out);
    await page.click('#film-color');await page.selectOption('#export-format','tiff');await page.click('#export-photos');
    await page.waitForFunction(()=>document.querySelector('#export-photos').textContent==='导出照片',{},{timeout:120000});
    const exports=(await fs.readdir(out)).filter(f=>f.startsWith('LightTable-'));assert(exports.length>0);let exported;
    for(const folder of exports)for(const name of await fs.readdir(path.join(out,folder)))if(name.endsWith('.tif'))exported=path.join(out,folder,name);
    assert(exported);assert.equal(sha(await fs.readFile(exported)),sha(await fs.readFile(developed.path)),'returned TIFF must export without regrading or quantization');
    assert.equal(sha(await fs.readFile(input)),originalHash);
    if(process.env.DOSE_REFERENCE_EXTENDED){
      // A second editing round must only replace the chosen derivative, even
      // when the untouched original has since been placed separately.
      if(await page.locator('#film-panel').isVisible())await page.click('#film-panel-close');
      await page.locator('.film-thumb').first().dblclick();await page.locator('.film-thumb').last().click();
      await page.click('#reference-editor');await editor.waitForTimeout(1200);
      await editor.waitForFunction(()=>!document.querySelector('.dose-toolbar button').disabled,{},{timeout:120000});
      await editor.getByRole('button',{name:'完成并返回 dose',exact:true}).click();
      await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===3,{},{timeout:180000});
      const repeated=(await page.evaluate(()=>window.lighttable.load())).state;
      assert(repeated.items.some(i=>i.photoId===original.id),'separately placed original must survive a later derivative edit');
      assert(!repeated.items.some(i=>i.photoId===developed.id),'only the selected prior derivative is replaced');
    }
    await app.close();app=null;
    app=await _electron.launch(config);const restored=await app.firstWindow();await restored.waitForFunction(()=>document.body.dataset.ready==='true');
    await restored.locator('.film-thumb').last().click();await restored.click('#reference-editor');editor=await app.waitForEvent('window');
    await editor.waitForFunction(()=>{const b=document.querySelector('.dose-toolbar button');return b&&!b.disabled;},{},{timeout:120000});
    await editor.waitForTimeout(1000);
    await editor.screenshot({path:path.join(out,'04-reopened-source.png')});
    assert((await editor.locator('[data-stock="kodak_tri_x_400"]').getAttribute('class')).includes('selected'));
    if(process.env.DOSE_REFERENCE_EXTENDED){assert.equal(Number(await editor.getByTestId('adj-exposure').locator('input').inputValue()),.35);}
    const reopen=await editor.locator('body').innerText();assert(reopen.includes(path.basename(input)));assert(!reopen.includes(path.basename(developed.path)+' ·'));
    assert.deepEqual(errors,[]);
    if(process.env.DOSE_REFERENCE_EXTENDED){const exposure=editor.getByTestId('adj-exposure').locator('input');await exposure.fill('0.7');await exposure.press('Enter');}
    await app.evaluate(({BrowserWindow})=>{BrowserWindow.getAllWindows().find(w=>w.webContents.getURL().startsWith('dose-editor:')).close();});
    await editor.waitForEvent('close',{timeout:15000});
    if(process.env.DOSE_REFERENCE_EXTENDED){
      const saved=JSON.parse(await fs.readFile(path.join(profile,'reference-editor','sidecars',sidecars[0]),'utf8'));assert.equal(saved.adjustments.exposure,.7,'close must flush a just-edited setting');
    }
    await fs.writeFile(path.join(out,'verification.json'),JSON.stringify({passed:true,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,input,originalHash,profile,developed,metadata:{width:metadata.width,height:metadata.height,bits:metadata.bitsPerSample,depth:metadata.depth,icc:metadata.icc.length},sidecar,backend:state.hello,checks:['original complete editor with native Vulkan','Tri-X selected in full UI','16-bit tagged TIFF returned','table replaces selected photo while retaining original','source file unchanged','restart reopens original with saved film recipe'],errors},null,2));
    console.log('Reference editor integration passed',out);
  }catch(e){if(editor&&!editor.isClosed()){await editor.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});await fs.writeFile(path.join(out,'failure-dom.txt'),await editor.locator('body').innerText().catch(()=>''));}throw e;}
  finally{await app?.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
