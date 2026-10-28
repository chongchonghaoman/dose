const {_electron,expect}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp');

const root=path.resolve(__dirname,'..');
const out=path.resolve(process.env.DOSE_REFERENCE_OUTPUT||path.join(__dirname,'results/reference-validation-pair'));
const fixtures=path.join(__dirname,'fixtures');
const inputs=[path.join(fixtures,'01-valley.jpg'),path.join(fixtures,'02-river.jpg')];

(async()=>{
  await fs.mkdir(out,{recursive:true});
  const profile=await fs.mkdtemp(path.join(out,'profile-'));
  const env={...process.env,LIGHTTABLE_USER_DATA:profile}; delete env.ELECTRON_RUN_AS_NODE;
  const config=process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env};
  let app,page,editor; const errors=[];
  const start=async()=>{ app=await _electron.launch(config); page=await app.firstWindow(); page.on('pageerror',e=>errors.push(e.message)); await page.waitForFunction(()=>document.querySelector('#spectral-status')?.dataset.available==='true'); };
  try {
    await start();
    await app.evaluate(({dialog},files)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:files});},inputs);
    await page.click('#import');
    await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===2,null,{timeout:120000});
    const first=page.locator('.film-thumb').nth(0), second=page.locator('.film-thumb').nth(1);
    await first.click(); await second.click({modifiers:['Control']});
    await page.click('#reference-editor'); editor=await app.waitForEvent('window'); editor.on('pageerror',e=>errors.push(e.message));
    await editor.waitForURL('dose-editor://app/index.html');
    await editor.getByTestId('film-list').waitFor({timeout:90000});
    await editor.waitForFunction(()=>document.querySelector('[data-testid="create-pair"]')&&!document.querySelector('[data-testid="create-pair"]').disabled,{},{timeout:120000});
    await editor.screenshot({path:path.join(out,'01-editor-before-pair.png')});
    const sourceNames=await editor.locator('[data-testid="filmstrip"] [data-path]').evaluateAll(es=>es.map(e=>e.textContent||e.getAttribute('data-path')));
    assert(sourceNames.length>=2,'editor must expose at least two source frames');
    await editor.locator('[data-testid="filmstrip"] [data-path]').nth(0).click();
    await editor.locator('[data-testid="filmstrip"] [data-path]').nth(1).click({modifiers:['Control']});
    await editor.getByTestId('create-pair').click();
    await editor.waitForFunction(()=>document.querySelector('[data-testid="filmstrip"]')?.innerText.includes('.spektrapair'),{},{timeout:120000});
    const pairState=await editor.evaluate(()=>window.doseEditor.invoke('state',[]));
    await editor.screenshot({path:path.join(out,'02-pair-created.png')});
    await editor.waitForFunction(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent==='完成并返回 dose');return b&&!b.disabled;},{},{timeout:180000});
    await editor.getByRole('button',{name:'完成并返回 dose',exact:true}).click();
    await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===3,null,{timeout:180000});
    const returned=await page.evaluate(()=>window.lighttable.load());
    const pairPhoto=returned.state.photos.find(p=>/spektrapair|pair/i.test(p.path||p.name||''));
    assert(pairPhoto,'returned dose library must contain a pair-derived photo');
    assert.equal(returned.state.photos.length,3,'two imported source photos plus developed pair');
    const meta=await sharp(pairPhoto.path).metadata();
    assert.equal(meta.format,'tiff'); assert.equal(meta.depth,'ushort'); assert.equal(meta.bitsPerSample,16);
    await page.screenshot({path:path.join(out,'03-pair-returned-to-dose.png')});
    await app.close(); app=null;
    await start();
    await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===3,null,{timeout:120000});
    const restoredThumb=page.locator('.film-thumb').filter({hasText:path.basename(pairPhoto.path)});
    assert.equal(await restoredThumb.count(),1);await restoredThumb.click();
    await page.click('#reference-editor'); editor=await app.waitForEvent('window');
    await editor.getByTestId('film-list').waitFor({timeout:90000});
    await editor.waitForFunction(()=>document.querySelector('[data-testid="filmstrip"]')?.innerText.includes('.spektrapair'),{},{timeout:120000});
    await editor.waitForFunction(()=>!document.querySelector('.dose-toolbar button')?.disabled,{},{timeout:120000});
    const associations=JSON.parse(await fs.readFile(path.join(profile,'reference-editor','associations.json'),'utf8'));
    const association=associations[path.resolve(pairPhoto.path).toLowerCase()];assert(association?.source.endsWith('.spektrapair'));
    const pair=JSON.parse(await fs.readFile(association.source,'utf8'));assert.equal(path.resolve(pair.left.path),inputs[0]);assert.equal(path.resolve(pair.right.path),inputs[1]);
    const reopen=await editor.locator('body').innerText();
    assert(reopen.includes(path.basename(inputs[0])),'reopened pair must retain first source');
    assert(reopen.includes(path.basename(inputs[1])),'reopened pair must retain second source');
    await editor.screenshot({path:path.join(out,'04-pair-reopened.png')});
    assert.deepEqual(errors,[]);
    await fs.writeFile(path.join(out,'verification.json'),JSON.stringify({passed:true,profile,inputs,pairPhoto,metadata:{width:meta.width,height:meta.height,depth:meta.depth,bitsPerSample:meta.bitsPerSample},checks:['two source frames selected','create-pair rendered pair','16-bit TIFF returned to dose','restart reopens pair with both sources'],errors},null,2));
    console.log('Reference pair integration passed',out);
  } catch(e) {
    if(editor&&!editor.isClosed()){await editor.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});await fs.writeFile(path.join(out,'failure-dom.txt'),await editor.locator('body').innerText().catch(()=>''));}
    await fs.writeFile(path.join(out,'failure.json'),JSON.stringify({message:e.message,stack:e.stack,errors},null,2)).catch(()=>{}); throw e;
  } finally { await app?.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
