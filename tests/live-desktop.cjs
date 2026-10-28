const {_electron}=require('playwright'),fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),out=path.join(__dirname,'results/live'),profile=path.join(out,'profile-'+Date.now());
const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
(async()=>{await fs.mkdir(out,{recursive:true});let app;const errors=[],checks=[];try{
app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});const page=await app.firstWindow();page.on('pageerror',e=>{errors.push(e.message);console.log('PAGEERROR',e.message)});page.on('console',m=>{if(m.text().includes('Live preview:')){errors.push(m.text());console.log(m.text())}});await page.reload();await page.waitForTimeout(700);
assert.deepEqual(errors,[]);
await app.evaluate(({dialog},folder)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[folder]})},path.join(__dirname,'fixtures'));await page.click('#import-folder');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===6);await page.locator('#toast button').click();await page.click('#film-color');
async function saved(){await page.waitForTimeout(700);return JSON.parse(await fs.readFile(path.join(profile,'table.json'),'utf8'))}
assert(await page.locator('#film-exposure').isDisabled());assert(await page.locator('#lut-library').isDisabled());const before=await saved();checks.push('No selection disables photo adjustments');
await page.locator('.film-thumb').first().click();await page.waitForTimeout(700);assert(!(await page.locator('#film-exposure').isDisabled()));
const films=await page.evaluate(()=>window.lighttable.filmStatus());await page.selectOption('#lut-library',films.library[0].hash);await page.waitForTimeout(500);
const start=Number(await page.locator('#table').getAttribute('data-live-frames')||0);
await page.locator('#film-exposure').evaluate(async el=>{for(let i=0;i<45;i++){el.value=String(i*.04);el.dispatchEvent(new Event('input',{bubbles:true}));await new Promise(r=>setTimeout(r,30))}});
const frames=Number(await page.locator('#table').getAttribute('data-live-frames')||0)-start;assert(frames>=3,`Only ${frames} live frames before release`);checks.push(`${frames} preview frames during continuous input before release`);
await page.screenshot({path:path.join(out,'live-preview.png')});
await page.locator('#film-exposure').evaluate(el=>{el.value='0.37';el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))});let s=await saved();assert.equal(s.photos[0].adjustments.exposure,.37);assert.deepEqual(s.photos.slice(1).map(p=>p.adjustments),before.photos.slice(1).map(p=>p.adjustments));checks.push('Only clicked photo changes; all other photos remain identical');
await page.locator('#table').focus();await page.keyboard.press('Control+z');s=await saved();assert.equal(s.photos[0].adjustments.exposure,0);checks.push('One undo restores entire slider gesture');
await page.locator('#table').focus();await page.keyboard.press('Control+a');await page.locator('#film-contrast').evaluate(el=>{el.value='12.3';el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))});s=await saved();assert(s.photos.every(p=>p.adjustments.contrast===12.3));checks.push('Explicit multi-selection changes only selected photos');
assert.deepEqual(errors,[]);await fs.writeFile(path.join(out,'report.json'),JSON.stringify({packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,errors,frames},null,2));console.log(checks.join('\n'));
}catch(e){console.error(e);process.exitCode=1}finally{await app?.close()}})();
