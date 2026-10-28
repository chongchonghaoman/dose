const {_electron:electron}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const sharp=require('sharp');
const root=path.resolve(__dirname,'..'),out=path.join(__dirname,'results');
const data=path.join(out,'profile-'+Date.now());
const env={...process.env,LIGHTTABLE_USER_DATA:data};delete env.ELECTRON_RUN_AS_NODE;
let app,page;const errors=[],report=[];
async function launch(){app=await electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')console.log('CONSOLE '+m.text());});await page.waitForSelector('#empty-state',{state:'attached'});await page.waitForTimeout(400);}
async function shot(name){await page.screenshot({path:path.join(out,name+'.png')});}
async function saved(){await page.waitForTimeout(550);return JSON.parse(await fs.readFile(path.join(data,'table.json'),'utf8'));}
async function check(name,fn){await fn();report.push({name,passed:true});console.log('PASS '+name);}
(async()=>{await fs.mkdir(out,{recursive:true});try{
  await launch();
  await check('Native window and empty state',async()=>{assert.equal(await page.locator('#empty-state').isVisible(),true);await shot('01-empty');});
  const fixtureDir=path.join(__dirname,'fixtures');
  await fs.mkdir(fixtureDir,{recursive:true});
  if(!(await fs.readdir(fixtureDir)).some(f=>/\.(jpg|png)$/i.test(f)))await require('./make-fixtures.cjs')(fixtureDir);
  await fs.writeFile(path.join(fixtureDir,'broken.jpg'),'not an image');
  await app.evaluate(({dialog},folder)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[folder]});},fixtureDir);
  await check('Folder import, invalid-image recovery and full-frame orientation',async()=>{
    await page.click('#import-folder');await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===6,null,{timeout:60000});
    await page.waitForTimeout(1200);const s=await saved();assert.equal(s.photos.length,6);assert.equal(s.items.length,6);assert.equal(s.photos.some(p=>p.height>p.width),true);
    assert.match(await page.locator('#toast').innerText(),/无法读取/);await page.locator('#toast button').click();await shot('02-light-table');
  });
  await check('Local-only renderer and image access control',async()=>{
    assert.equal(await page.evaluate(()=>typeof require),'undefined');assert.equal(await page.evaluate(()=>typeof process),'undefined');
    const result=await page.evaluate(async()=>{const r=await fetch('photo://unregistered/image');return r.status;});assert.equal(result,404);
  });
  await check('Lamp toggles change actual image pixels',async()=>{
    const before=await page.locator('#table').screenshot();await page.click('#power');await page.waitForTimeout(900);await shot('03-lamp-off');const after=await page.locator('#table').screenshot();
    const a=await sharp(before).stats(),b=await sharp(after).stats();assert(a.channels[0].mean>b.channels[0].mean+30);assert.equal((await saved()).lit,false);await page.click('#power');await page.waitForTimeout(900);
  });
  await check('Drag, rotate, scale, mount, remove and undo',async()=>{
    let s=await saved();const box=await page.locator('#table').boundingBox(),i=s.items[0],x=box.x+box.width/2+s.camera.x+i.x*s.camera.zoom,y=box.y+box.height/2+s.camera.y+i.y*s.camera.zoom;
    await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+55,y+30,{steps:8});await page.mouse.up();let next=await saved();assert(Math.abs(next.items.find(a=>a.id===i.id).x-i.x)>30);
    await page.click('#rotate-right');await page.click('#scale-up');await page.click('#mount');next=await saved();const m=next.items.find(a=>a.id===i.id);assert.equal(m.angle,5);assert(m.width>i.width);assert.equal(m.mount,'slide');
    await page.click('#remove');assert.equal((await saved()).items.length,5);await page.keyboard.press('Control+z');assert.equal((await saved()).items.length,6);await shot('04-mounted');
  });
  await check('Loupe, close inspection and 8x mode render',async()=>{
    if(await page.locator('#toast').isVisible())await page.locator('#toast button').click();await page.click('#loupe');const b=await page.locator('#table').boundingBox();await page.mouse.move(b.x+b.width*.4,b.y+b.height*.48,{steps:5});await page.waitForTimeout(600);assert.equal(await page.locator('#table').getAttribute('data-loupe-visible'),'true');await shot('05-loupe');
    await page.keyboard.press('Tab');await page.keyboard.down('Space');await page.waitForTimeout(900);await shot('06-closeup');assert.match(await page.locator('#magnification').innerText(),/8×/);await page.keyboard.up('Space');await page.keyboard.press('a');
  });
  await check('Sleeve arrangement retains photos and groups six pockets',async()=>{
    await page.keyboard.press('Escape');await page.click('#sleeve');const s=await saved();assert.equal(s.items.length,6);assert.equal(new Set(s.items.map(i=>i.group)).size,1);assert(s.items[0].group);await page.locator('#toast button').click();await shot('07-sleeves');
  });
  await check('Projection displays local full image, navigation, shuffle and exit',async()=>{
    await page.click('#slideshow');await page.waitForFunction(()=>document.querySelector('#projected-image').naturalWidth>0);await page.waitForTimeout(700);assert.equal(await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].isFullScreen()),true);await shot('08-projection');
    const name=await page.locator('#slide-name').innerText();await page.keyboard.press('ArrowRight');await page.waitForTimeout(700);assert.notEqual(await page.locator('#slide-name').innerText(),name);await page.click('#shuffle');assert.equal(await page.locator('#shuffle').getAttribute('aria-pressed'),'true');await page.keyboard.press('Escape');await page.waitForTimeout(500);assert.equal(await page.locator('#projection').isVisible(),false);
  });
  await check('Export, backup on new table, and re-open layout',async()=>{
    const file=path.join(out,'exported.lighttable.json');
    await app.evaluate(({dialog},p)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:p});dialog.showMessageBox=async()=>({response:1});},file);
    await page.click('#export-layout');await page.waitForTimeout(400);assert.equal(JSON.parse(await fs.readFile(file,'utf8')).photos.length,6);
    await page.click('#new-layout');await page.waitForTimeout(600);assert.equal(await page.locator('.film-thumb').count(),0);assert.equal((await fs.readdir(path.join(data,'backups'))).length,1);
    await app.evaluate(({dialog},p)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[p]});},file);await page.click('#open-layout');await page.waitForTimeout(700);assert.equal(await page.locator('.film-thumb').count(),6);
  });
  const before=await saved();
  await check('Layout survives application restart',async()=>{await app.close();await launch();await page.waitForTimeout(1000);const after=JSON.parse(await fs.readFile(path.join(data,'table.json'),'utf8'));assert.deepEqual(after.items,before.items);assert.equal(await page.locator('.film-thumb').count(),6);});
  await check('Minimum desktop size keeps controls in view',async()=>{await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(1000,720));await page.waitForTimeout(400);const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert.equal(overflow,false);await shot('09-small-window');});
  await check('No uncaught renderer errors',async()=>assert.deepEqual(errors,[]));
  await fs.writeFile(path.join(out,'report.json'),JSON.stringify({testedAt:new Date().toISOString(),packaged:!!process.env.LIGHTTABLE_EXECUTABLE,report,errors,data},null,2));
}catch(e){console.error(e);if(page)await shot('failure').catch(()=>{});process.exitCode=1;}finally{if(app)await app.close().catch(()=>{});}})();
