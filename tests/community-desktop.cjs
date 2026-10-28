const {_electron}=require('playwright'),fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict'),sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.env.DOSE_COMMUNITY_OUTPUT||path.join(__dirname,'results/community-desktop'));
(async()=>{await fs.mkdir(out,{recursive:true});const profile=path.join(out,'ui-profile-'+Date.now()),env={...process.env,LIGHTTABLE_USER_DATA:profile};delete env.ELECTRON_RUN_AS_NODE;
 let app;const errors=[];
 try{app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});const page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));
 await page.waitForFunction(()=>document.querySelector('#spectral-status').dataset.available==='true');
 const input=path.join(__dirname,'fixtures/01-valley.jpg');await app.evaluate(({dialog},input)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[input]});},input);
 await page.click('#import');await page.locator('.film-thumb').first().waitFor();await page.locator('.film-thumb').first().dblclick();await page.click('#film-color');
 await page.waitForFunction(()=>!document.querySelector('#film-engine').disabled);await page.selectOption('#film-engine','spectral');
 await page.locator('#spectral-native-controls').waitFor({state:'visible'});await page.locator('#spectral-native-controls summary').click();
 await page.locator('label:has(#spectral-edge)').click();await page.locator('label:has(#spectral-date)').click();await page.locator('#spectral-date-text').fill('2026-10-29');await page.locator('#spectral-date-text').dispatchEvent('change');
 await page.waitForFunction(()=>Number(document.querySelector('#table').dataset.spectralFrames)>0);await page.waitForTimeout(1500);
 const state=JSON.parse(await fs.readFile(path.join(profile,'table.json'),'utf8'));assert.equal(state.photos[0].adjustments.spectralEdge,true);assert.equal(state.photos[0].adjustments.spectralDateText,'2026-10-29');
 await page.screenshot({path:path.join(out,'dose-community-ui.png')});
 await app.evaluate(({dialog},out)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[out]});},out);await page.selectOption('#export-format','png');await page.click('#export-photos');
 await page.waitForFunction(()=>document.querySelector('#export-photos').textContent==='导出照片');
 const folders=(await fs.readdir(out)).filter(f=>f.startsWith('LightTable-'));let exported;
 for(const folder of folders){for(const f of await fs.readdir(path.join(out,folder)))if(f.endsWith('.png')&&f.includes('01-valley'))exported=path.join(out,folder,f);}
 assert(exported,'PNG selection must export PNG');
 const metadata=await sharp(exported).metadata();assert.equal(metadata.format,'png');assert(metadata.icc?.length>0);
 await app.close();app=null;
 app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});const restored=await app.firstWindow();await restored.waitForFunction(()=>document.querySelector('#spectral-status').dataset.available==='true');
 await restored.locator('.film-thumb').first().click();await restored.click('#film-color');await restored.locator('#spectral-native-controls summary').click();assert(await restored.locator('#spectral-edge').isChecked());assert.equal(await restored.locator('#spectral-date-text').inputValue(),'2026-10-29');
 assert.deepEqual(errors,[]);await fs.writeFile(path.join(out,'desktop-report.json'),JSON.stringify({passed:true,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks:['Actual Electron controls persist edge/date','PNG chosen in UI writes PNG with ICC','Restart restores settings'],errors},null,2));console.log('Desktop checks passed');
 }finally{await app?.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
