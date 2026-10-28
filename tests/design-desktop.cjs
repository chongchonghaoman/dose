const {_electron}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),out=path.join(__dirname,'results','design'),profile=path.join(out,'profile-'+Date.now());
const env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
(async()=>{
 await fs.mkdir(out,{recursive:true});
 const app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});
 const page=await app.firstWindow(),errors=[],checks=[];page.on('pageerror',e=>errors.push(e.message));
 async function shot(name){await page.waitForTimeout(450);await page.screenshot({path:path.join(out,name+'.png')});}
 async function check(name,fn){await fn();checks.push(name);console.log('PASS '+name);}
 try{
 await page.waitForSelector('#empty-import');await shot('01-empty');
 await app.evaluate(({dialog},p)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[p]});},path.join(__dirname,'fixtures'));
 await page.click('#import-folder');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===6);await page.locator('#toast button').click();
 await page.waitForTimeout(800);await shot('02-library');
 await page.click('#film-color');await page.click('#fit');await page.waitForTimeout(150);
 await check('Docked inspector does not cover the light table',async()=>{const a=await page.locator('#stage').boundingBox(),b=await page.locator('#film-panel').boundingBox();assert(a.x+a.width<=b.x);});
 await check('Thumbnail colors are not darkened by UI filters',async()=>{assert.equal(await page.locator('.sleeve-thumb img').first().evaluate(e=>getComputedStyle(e).filter),'none');});
 await page.locator('.film-thumb').first().click();
 const exposure=page.locator('#film-exposure');await exposure.evaluate(e=>{e.value=1;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));});
 await check('Double click resets an individual adjustment',async()=>{await exposure.dblclick();assert.equal(await exposure.inputValue(),'0');});
 await shot('03-inspector');
 await check('Escape closes inspector and returns keyboard focus',async()=>{await exposure.focus();await page.keyboard.press('Escape');assert(await page.locator('#film-panel').isHidden());assert(await page.locator('#film-color').evaluate(e=>e===document.activeElement));});
 await page.click('#film-color');
 await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(980,680));await page.waitForTimeout(300);await page.click('#fit');
 await check('Minimum-size inspector exposes last slider without footer overlap',async()=>{await page.locator('#film-bloom').scrollIntoViewIfNeeded();const slider=await page.locator('#film-bloom').boundingBox(),foot=await page.locator('.film-panel-foot').boundingBox();assert(slider.y+slider.height<=foot.y+1);const panel=await page.locator('#film-panel').boundingBox(),stage=await page.locator('#stage').boundingBox();assert(panel.x>=stage.x+stage.width);});
 await shot('04-minimum');
 await page.click('#film-panel-close');await page.click('#help');await shot('05-help');await page.keyboard.press('Escape');
 assert.deepEqual(errors,[]);await fs.writeFile(path.join(out,'report.json'),JSON.stringify({packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,errors},null,2));
 }catch(e){await shot('failure');throw e;}finally{await app.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
