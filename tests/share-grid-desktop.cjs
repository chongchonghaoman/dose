const {_electron}=require('playwright');
const fs=require('node:fs/promises');
const path=require('node:path');
const assert=require('node:assert/strict');
const sharp=require('sharp');

const root=path.resolve(__dirname,'..');
const version=require('../package.json').version;
const out=path.resolve(root,'../../outputs/v'+version+'/verification');
const work=path.join(__dirname,'results','share-grid-'+Date.now());
const fixtures=path.join(work,'fixtures');
const folder=path.join(work,'export-parent');
const profile=path.join(work,'profile');
const env={...process.env,LIGHTTABLE_USER_DATA:profile};
delete env.ELECTRON_RUN_AS_NODE;
const checks=[],errors=[];
let app,page;

async function makeFixtures(){
  await fs.mkdir(fixtures,{recursive:true}); await fs.mkdir(folder,{recursive:true});
  const names=['01-valley.jpg','02-river.jpg','03-cliff.jpg','04-waterfall.jpg','05-landscape.jpg','06-castle.jpg'];
  for(let i=0;i<18;i++){
    const src=path.join(__dirname,'fixtures',names[i%names.length]);
    await sharp(src).resize(900+(i%3)*120,700+(i%4)*80,{fit:'cover'}).jpeg({quality:92}).toFile(path.join(fixtures,String(i+1).padStart(2,'0')+'.jpg'));
  }
}
async function start(){
  app=await _electron.launch(process.env.LIGHTTABLE_EXECUTABLE?{executablePath:process.env.LIGHTTABLE_EXECUTABLE,args:[],env}:{args:[root],env});
  page=await app.firstWindow();
  await app.evaluate(({BrowserWindow})=>{const w=BrowserWindow.getAllWindows()[0];w.webContents.setBackgroundThrottling(false);w.hide();});
  page.on('pageerror',e=>errors.push(e.message));
  await page.waitForSelector('#import-folder');
}
async function state(){return (await page.evaluate(()=>window.lighttable?.load?.())).state;}
async function shot(name){await page.screenshot({path:path.join(out,'share-grid-'+name+'.png')});}
async function check(name,fn){await fn();checks.push(name);console.log('PASS '+name);}
async function setRange(id,value){await page.locator(id).evaluate((el,v)=>{el.value=String(v);el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));},value);await page.waitForTimeout(120);}
async function exportOnce(label,mag,guides){
  await app.evaluate(({dialog},output)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[output]});},folder);
  const before=new Set((await fs.readdir(folder,{withFileTypes:true})).filter(x=>x.isDirectory()&&x.name.startsWith('dose-九宫格-')).map(x=>x.name));
  await setRange('#share-mag',mag); await page.locator('#share-guides').setChecked(guides);
  await page.click('#share-export');
  await page.waitForFunction(()=>{const b=document.querySelector('#share-export');return b&&!b.disabled;},{timeout:60000});
  await page.waitForSelector('#share-open-folder',{state:'visible',timeout:60000});
  const dirs=(await fs.readdir(folder,{withFileTypes:true})).filter(x=>x.isDirectory()&&x.name.startsWith('dose-九宫格-')&&!before.has(x.name)).map(x=>path.join(folder,x.name));
  assert.equal(dirs.length,1,'expected one new export directory'); const dir=dirs[0];
  const files=(await fs.readdir(dir)).filter(x=>/^[0-9]{2}\.jpg$/.test(x)).sort();
  assert.deepEqual(files,Array.from({length:9},(_,i)=>String(i+1).padStart(2,'0')+'.jpg'));
  for(const f of files){const m=await sharp(path.join(dir,f)).metadata();assert.equal(m.width,1440);assert.equal(m.height,1440);assert.equal(m.format,'jpeg');assert(m.icc,'missing ICC profile');}
  const inputs=await Promise.all(files.map(f=>sharp(path.join(dir,f)).resize(480,480).toBuffer()));
  await sharp({create:{width:1440,height:1440,channels:3,background:{r:245,g:245,b:245}}}).composite(inputs.map((input,i)=>({input,left:(i%3)*480,top:Math.floor(i/3)*480}))).png().toFile(path.join(out,'share-grid-'+label+'-joined.png'));
  return {dir,files};
}
(async()=>{
  await fs.mkdir(out,{recursive:true}); await makeFixtures();
  try{
    await start();
    await app.evaluate(({dialog},[input,output])=>{let n=0;dialog.showOpenDialog=async()=>({canceled:false,filePaths:[n++?output:input]});},[fixtures,folder]);
    await page.click('#import-folder');
    await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length===18,null,{timeout:60000});
    await page.waitForTimeout(700);
    const before=await state();
    await check('Grid controls open as a centered cropped modal at desktop size',async()=>{
      await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setSize(980,680));
      await page.locator('.film-thumb').nth(7).click(); await page.click('#share-grid');
      await page.waitForSelector('#share-dialog'); assert(await page.locator('#share-dialog').isVisible());
      assert(await page.locator('#share-canvas').isVisible()); assert(await page.locator('#share-focus').isVisible());
      const db=await page.locator('#share-dialog').boundingBox(); assert(db.y>=60,'dialog overlaps native window controls');
      const b=await page.locator('#share-canvas').boundingBox(),v=await page.evaluate(()=>({w:innerWidth,h:innerHeight}));
      assert(Math.abs(b.width-b.height)<2); assert(b.x>=0&&b.y>=0&&b.x+b.width<=v.w&&b.y+b.height<=v.h);
      assert.equal(await page.locator('#share-focus').inputValue(),await page.locator('#share-focus option').nth(7).getAttribute('value')); await shot('01-open');
    });
    await check('Focus, crop range, lens and centre are interactive without mutating the source scene',async()=>{
      const original=JSON.stringify(await state());
      const options=await page.locator('#share-focus option').count(); assert.equal(options,18);
      await page.selectOption('#share-focus',{index:2}); await setRange('#share-range',180); await setRange('#share-mag',3); await setRange('#share-lens',18); await page.click('#share-center');
      await page.locator('#share-background').selectOption('dark'); await page.locator('#share-canvas').dispatchEvent('wheel',{deltaY:120});
      const cb=await page.locator('#share-canvas').boundingBox(); await page.mouse.move(cb.x+cb.width*.45,cb.y+cb.height*.45); await page.mouse.down(); await page.mouse.move(cb.x+cb.width*.6,cb.y+cb.height*.55); await page.mouse.up();
      assert.equal(JSON.stringify(await state()),original); await shot('02-controls');
    });
    await check('Export is nine exact sRGB JPEGs and restores the busy button',async()=>{
      const a=await exportOnce('mag1',1,true); assert(await page.locator('#share-open-folder').isVisible());
      const bytes=await fs.readFile(path.join(a.dir,'05.jpg'));
      const b=await exportOnce('mag2',2,true); const bytes2=await fs.readFile(path.join(b.dir,'05.jpg'));
      assert.notDeepEqual(bytes,bytes2,'magnifier does not materially alter output'); await shot('03-exported');
    });
    await check('Guides are excluded from export and focus survives close/reopen',async()=>{
      await page.click('#share-close'); await page.locator('.film-thumb').nth(2).click(); await page.click('#share-grid');
      assert.equal(await page.locator('#share-focus').inputValue(),await page.locator('#share-focus option').nth(2).getAttribute('value'));
      const on=await exportOnce('guides-on',1,true); await page.click('#share-close'); await page.click('#share-grid');
      const off=await exportOnce('guides-off',1,false);
      assert.deepEqual(await fs.readFile(path.join(on.dir,'05.jpg')),await fs.readFile(path.join(off.dir,'05.jpg')));
    });
    await check('DNG spectral and HEIC sources enter the sharing path without source mutation',async()=>{
      const dng=path.join(__dirname,'dng-fixtures','Apple-iPhone-12-Pro.DNG');
      const heic=path.join(__dirname,'heic-fixtures','example.heic');
      const crypto=require('node:crypto'); const dngSha=crypto.createHash('sha256').update(await fs.readFile(dng)).digest('hex'); const heicSha=crypto.createHash('sha256').update(await fs.readFile(heic)).digest('hex');
      const beforeSmoke=await state(); await page.click('#share-close');
      await app.evaluate(({dialog},file)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[file]});},dng);
      await page.click('#import'); await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length>=19,null,{timeout:60000}); await page.waitForTimeout(700);
      await app.evaluate(({dialog},file)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[file]});},heic);
      await page.click('#import'); await page.waitForFunction(()=>document.querySelectorAll('.film-thumb').length>=20,null,{timeout:60000}); await page.waitForTimeout(700);
      const dngThumb=page.locator('.film-thumb').nth(18),heicThumb=page.locator('.film-thumb').nth(19); await dngThumb.dblclick(); await heicThumb.dblclick(); await page.waitForTimeout(700); await dngThumb.click(); await page.click('#film-color');
      if(await page.locator('#film-engine').count()){await page.selectOption('#film-engine','spectral');await page.waitForFunction(()=>Number(document.querySelector('#table')?.dataset.spectralFrames||0)>0,null,{timeout:60000});}
      await page.click('#film-panel-close').catch(()=>{}); await page.click('#share-grid'); await page.waitForSelector('#share-dialog');
      assert.equal(await page.locator('#share-focus').inputValue(),await page.locator('#share-focus option').nth(18).getAttribute('value')); const dngBefore=await state(); const dngOut=await exportOnce('dng-spectral',2,false); const dngAfter=await state(); assert.deepEqual(dngAfter.items,dngBefore.items); assert.deepEqual(dngAfter.editorialPages,dngBefore.editorialPages); assert.deepEqual(dngAfter.photos.map(p=>p.adjustments),dngBefore.photos.map(p=>p.adjustments));
      await page.click('#share-close'); await page.locator('.film-thumb').nth(19).click(); await page.click('#share-grid'); await page.waitForSelector('#share-canvas');
      assert(await page.locator('#share-canvas').isVisible()); const heicOut=await exportOnce('heic',2,false); assert.notDeepEqual(await fs.readFile(path.join(dngOut.dir,'05.jpg')),await fs.readFile(path.join(heicOut.dir,'05.jpg')),'different focus should change overlapping lens tile'); await page.click('#share-close');
      const afterSmoke=await state(); assert.deepEqual(afterSmoke.photos.slice(0,beforeSmoke.photos.length),beforeSmoke.photos); assert.equal(crypto.createHash('sha256').update(await fs.readFile(dng)).digest('hex'),dngSha); assert.equal(crypto.createHash('sha256').update(await fs.readFile(heic)).digest('hex'),heicSha);
    });
    assert.deepEqual(errors,[]);
    await fs.writeFile(path.join(out,'share-grid-report.json'),JSON.stringify({version,packaged:!!process.env.LIGHTTABLE_EXECUTABLE,checks,errors},null,2));
  }catch(e){console.error(e);if(page)await page.screenshot({path:path.join(out,'share-grid-failure.png')}).catch(()=>{});process.exitCode=1;}
  finally{if(app)await app.close().catch(()=>{});}
})();
