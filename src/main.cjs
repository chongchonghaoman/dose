const { app, BrowserWindow, ipcMain, dialog, protocol, net, Menu, nativeTheme, shell } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { pathToFileURL } = require('node:url');
const sharp = require('sharp');
const { Worker } = require('node:worker_threads');
const { cleanAdjustments, hasEdits, parseCube } = require('./film.cjs');
const { supported, cleanState } = require('./core.cjs');
const { LutLibrary } = require('./lut-library.cjs');
const {createHeicCache}=require('./heic.cjs');
const {createDngCache}=require('./dng.cjs');
const {hasLegacyAutoFit,backupLegacyAutoFit}=require('./auto-fit-migration.cjs');
const {writeGridExport}=require('./grid-export.cjs');
const {writeMagazineExport}=require('./magazine-export.cjs');
const {photoAvailability}=require('./photo-availability.cjs');
const {createReferenceEditor}=require('./reference-editor.cjs');
const {createUiPreferences}=require('./ui-preferences.cjs');
let imageInput, spectralInput;
const inputFor=(file,a)=>a.engine==='spectral'&&a.spectralVersion===2?spectralInput(file):imageInput(file);
// Retain the established library location across the dose rebrand.
app.setPath('userData', process.env.LIGHTTABLE_USER_DATA || path.join(app.getPath('appData'),'lighttable-windows'));
app.setName('dose');
app.setAppUserModelId('dose.desktop');
nativeTheme.themeSource = 'dark';
protocol.registerSchemesAsPrivileged(['photo','dose-editor'].map(scheme=>({scheme,privileges:{standard:true,secure:true,supportFetchAPI:true,corsEnabled:true,stream:true}})));
let win, stateFile, cacheDir, state = cleanState(null), writeQueue = Promise.resolve(), importing = false;
if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => { if(win){if(win.isMinimized())win.restore();win.show();win.focus();} });
const allowed = new Map(), jobs = new Map();
let lutLibrary, filmWorker = null, filmJob = 0, exporting = false, lastExportFolder = null;
let uiPreferences;
let gridOutput=null,gridWrite=null;
const filmJobs = new Map();
function filmStatus() { return lutLibrary.status(); }
function renderFilm(job) {
  if(!filmWorker){
    filmWorker=new Worker(path.join(__dirname,'film-worker.cjs'));
    filmWorker.on('message',result=>{const pending=filmJobs.get(result.id);if(pending){filmJobs.delete(result.id);result.error?pending.reject(Error(result.error)):pending.resolve(result.result);}});
    filmWorker.on('error',e=>{for(const p of filmJobs.values())p.reject(e);filmJobs.clear();filmWorker=null;});
  }
  const id=++filmJob;return new Promise((resolve,reject)=>{filmJobs.set(id,{resolve,reject});filmWorker.postMessage({...job,id});});
}
sharp.cache({ memory: 80, files: 12, items: 40 });
sharp.concurrency(2);
const idFor = p => crypto.createHash('sha256').update(path.resolve(p).toLowerCase()).digest('hex').slice(0, 24);
function persist(next) {
  state = cleanState(next);
  const serialized = JSON.stringify(state);
  writeQueue = writeQueue.catch(() => {}).then(async () => {
    await fs.mkdir(path.dirname(stateFile), { recursive: true });
    await fs.writeFile(stateFile + '.tmp', serialized, 'utf8');
    await fs.rename(stateFile + '.tmp', stateFile);
  });
  return writeQueue;
}
async function imageFile(id, size, edit = {}) {
  const p = allowed.get(id); if (!p) throw new Error('Unknown photo');
  const adjustments=cleanAdjustments(edit),lut=lutLibrary.resolve(adjustments.lutId);
  if(adjustments.engine!=='spectral'&&adjustments.lut&&!lut)throw Error('此照片的胶片配置缺失，请重新导入或关闭胶片色彩');
  const edited=hasEdits(adjustments);
  const stat = await fs.stat(p.path);
  const fingerprint = crypto.createHash('sha256').update(`${p.path}:${stat.mtimeMs}:${stat.size}:${size}${/\.dng$/i.test(p.path)?':raw-display-v2':''}${edited?':film-v10:'+JSON.stringify(adjustments)+':'+(adjustments.engine!=='spectral'&&adjustments.lut?lut.hash:''):''}`).digest('hex');
  const target = path.join(cacheDir, fingerprint + (edited&&adjustments.engine==='spectral'&&adjustments.spectralVersion===2?'.png':'.jpg'));
  try { await fs.access(target); return target; } catch {}
  if (!jobs.has(target)) jobs.set(target, (async () => {
    const input=await inputFor(p.path,adjustments);
    if(edited)await renderFilm({input,size,adjustments,lutPath:adjustments.engine!=='spectral'&&adjustments.lut?lut.path:null,output:target+'.tmp'});
    else await sharp(input, { limitInputPixels: 150000000, failOn: 'error' }).rotate().resize(size, size, { fit: 'inside', withoutEnlargement: true }).flatten({ background: '#ffffff' }).toColourspace('srgb').jpeg({ quality: size > 1600 ? 94 : 88 }).toFile(target + '.tmp');
    await fs.rename(target + '.tmp', target);
    return target;
  })().finally(() => jobs.delete(target)));
  return jobs.get(target);
}
async function collect(paths) {
  const found = [], visited = new Set();
  async function visit(p, depth = 0) {
    if (found.length >= 5000 || depth > 32) return;
    try {
      const stat = await fs.lstat(p);
      if (stat.isSymbolicLink()) return;
      if (stat.isDirectory()) {
        const real = await fs.realpath(p); if (visited.has(real)) return; visited.add(real);
        const entries = await fs.readdir(p, { withFileTypes: true });
        entries.sort((a,b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }));
        for (const e of entries) await visit(path.join(p, e.name), depth + 1);
      } else if (stat.isFile() && supported(p)) found.push(path.resolve(p));
    } catch {}
  }
  for (const p of paths) if (typeof p === 'string' && path.isAbsolute(p)) await visit(p);
  return [...new Set(found)];
}
async function importPaths(paths) {
  if (importing) return { photos: [], errors: ['正在导入，请稍候。'] };
  importing = true;
  try {
    const files = await collect(paths), photos = [], errors = [];
    for (let i = 0; i < files.length; i++) {
      const file = files[i], id = idFor(file);
      if (state.photos.some(p => p.id === id)) continue;
      try {
        const meta = await sharp(await imageInput(file), { limitInputPixels: 150000000 }).metadata();
        const rotated = [5,6,7,8].includes(meta.orientation);
        const p = { id, path: file, name: path.basename(file), width: rotated ? meta.height : meta.width, height: rotated ? meta.width : meta.height };
        allowed.set(id, p); await imageFile(id, 1600); photos.push(p);
      } catch { errors.push(path.basename(file)); allowed.delete(id); }
      if (win && !win.isDestroyed()) win.webContents.send('import-progress', { done: i + 1, total: files.length });
    }
    return { photos, errors, limit: files.length >= 5000 };
  } finally { importing = false; }
}
app.whenReady().then(async () => {
  uiPreferences = createUiPreferences(app.getPath('userData'));
  stateFile = path.join(app.getPath('userData'), 'table.json');
  cacheDir = path.join(app.getPath('userData'), 'previews');
  const heicInput=createHeicCache(path.join(app.getPath('userData'),'heic-cache'),renderFilm),dngInput=createDngCache(path.join(app.getPath('userData'),'dng-cache'),renderFilm);
  imageInput=async file=>dngInput(await heicInput(file));
  // HEIC's existing decoder is an explicit SDR fallback. DNG and other native
  // supported sources go straight to the host, never through the thumbnail PNG.
  spectralInput=heicInput;
  const referenceEditor=createReferenceEditor({getParent:()=>win,resolvePhoto:id=>allowed.get(id),importResult:file=>importPaths([file]),prepareInput:async file=>{
    const input=await spectralInput(file);
    if(!/\.(webp|avif|gif)$/i.test(input))return input;
    const dir=path.join(app.getPath('userData'),'reference-editor','inputs');await fs.mkdir(dir,{recursive:true});
    const stat=await fs.stat(input),target=path.join(dir,idFor(input+':'+stat.mtimeMs)+'.png');
    try{await fs.access(target);}catch{await sharp(input).pipelineColourspace('rgb16').rotate().flatten({background:'#ffffff'}).toColourspace('rgb16').png().toFile(target);}
    return target;
  }});
  ipcMain.handle('reference:open',(e,ids)=>{if(e.sender!==win?.webContents)throw Error('Unknown window');return referenceEditor.open(Array.isArray(ids)?ids.slice(0,5000):[]);});
  await fs.mkdir(cacheDir, { recursive: true });
  lutLibrary=new LutLibrary(path.join(app.getPath('userData'),'luts'),path.join(__dirname,'../assets/luts'));
  await lutLibrary.load();
  let warning = '';
  let loadedRaw,loadedBytes;
  try { loadedBytes=await fs.readFile(stateFile);loadedRaw=JSON.parse(loadedBytes.toString('utf8'));state=cleanState(loadedRaw); }
  catch (e) { if (e.code !== 'ENOENT') { warning = '上次布局无法读取，已保留原文件备份。'; await fs.copyFile(stateFile, stateFile + '.backup-' + Date.now()).catch(() => {}); } }
  if(hasLegacyAutoFit(loadedRaw)){
    try{await backupLegacyAutoFit(stateFile,loadedBytes);await persist(state);warning='旧版自动适配已关闭，手动调色已保留。';}
    catch{warning='旧版自动适配已在当前窗口关闭，但备份或保存失败，请检查磁盘空间。';}
  }
  for (const p of state.photos) {if(p.adjustments?.lut&&!p.adjustments.lutId)p.adjustments.lutId=lutLibrary.active;allowed.set(p.id, p);}
  protocol.handle('photo', async request => {
    try {
      const u = new URL(request.url), id = u.hostname;
      const requested = u.searchParams.get('size');
      const size = requested === 'full' ? 6000 : requested === 'thumb' ? 320 : ['48','96','320','800','1600','2400','3200','4320','6000'].includes(requested) ? Number(requested) : 1600;
      const serializedEdit=u.searchParams.get('edit');if(serializedEdit?.length>2048)throw Error('Invalid adjustments');
      const edit=serializedEdit?JSON.parse(serializedEdit):{};
      const response = await net.fetch(pathToFileURL(await imageFile(id, size, edit)).href);
      return new Response(response.body, { headers: { 'Content-Type': response.headers.get('content-type')||'image/jpeg', 'Access-Control-Allow-Origin': '*' } });
    } catch { return new Response('Photo missing or unreadable', { status: 404, headers: { 'Access-Control-Allow-Origin': '*' } }); }
  });
  ipcMain.handle('state:load', () => ({ state, warning, version: app.getVersion(), dataPath: app.getPath('userData') }));
  ipcMain.handle('ui-preferences:load', () => uiPreferences.load());
  ipcMain.handle('ui-preferences:save', (_, partial) => uiPreferences.save(partial));
  ipcMain.handle('photos:availability',async(_,ids)=>{
    const requested=[...new Set((Array.isArray(ids)?ids:[]).slice(0,5000).filter(id=>typeof id==='string'))];
    const known=requested.filter(id=>allowed.has(id)),result=await photoAvailability(known.map(id=>allowed.get(id)));
    return {available:result.available,unavailable:[...result.unavailable,...requested.filter(id=>!allowed.has(id))]};
  });
  ipcMain.handle('grid:choose-output',async()=>{
    if(exporting)throw Error('请等待当前导出完成。');
    const result=await dialog.showOpenDialog(win,{title:'选择九宫格导出位置',properties:['openDirectory','createDirectory']});
    if(result.canceled)return null;
    gridOutput={token:crypto.randomUUID(),parent:result.filePaths[0],expires:Date.now()+30*60*1000};return {token:gridOutput.token};
  });
  ipcMain.handle('grid:write',async(_,request)=>{
    if(exporting)throw Error('请等待当前导出完成。');
    if(!gridOutput||request?.token!==gridOutput.token||Date.now()>gridOutput.expires)throw Error('请重新选择九宫格导出位置。');
    const output=gridOutput;gridOutput=null;exporting=true;
    try{gridWrite=writeGridExport({image:request.image,parent:output.parent});const result=await gridWrite;lastExportFolder=result.folder;return result;}
    finally{gridWrite=null;exporting=false;}
  });
  ipcMain.handle('state:save', (_, next) => persist(next).then(() => true));
  ipcMain.handle('magazine:export',async(event,options)=>{
    if(event.sender!==win?.webContents)throw Error('Unknown window');
    if(exporting)throw Error('请等待当前导出完成。');
    const snapshot=structuredClone(state);
    snapshot.editorialPages=(snapshot.editorialPages||[]).filter(p=>p.kind!=='viewport');
    if(!snapshot.editorialPages.length)throw Error('请先生成杂志页面。');
    exporting=true;
    try{
      const result=await dialog.showOpenDialog(win,{title:'选择杂志页面导出位置',properties:['openDirectory','createDirectory']});
      if(result.canceled)return {canceled:true};
      const output=await writeMagazineExport({state:snapshot,parent:result.filePaths[0],format:options?.format,longEdge:options?.longEdge,
        resolveImage:async(photo,size)=>{if(!allowed.has(photo.id))throw Error('照片不可用：'+photo.name);return imageFile(photo.id,size,photo.adjustments);},
        onProgress:progress=>{if(!win.isDestroyed())win.webContents.send('magazine:progress',progress);}});
      lastExportFolder=output.folder;return output;
    }finally{exporting=false;}
  });
  ipcMain.handle('film:status',()=>filmStatus());
  ipcMain.handle('film:spectral-status',async()=>{try{return await renderFilm({kind:'spectral-status'});}catch(e){return {available:false,films:[],papers:[],error:e.message};}});
  ipcMain.handle('film:auto-fit',async(_,request)=>{
    const p=allowed.get(request?.id);if(!p)throw Error('Unknown photo');
    const adjustments=cleanAdjustments(request.adjustments),lut=lutLibrary.resolve(adjustments.lutId);
    if(adjustments.engine!=='spectral'&&adjustments.lut&&!lut)throw Error('此照片的胶片配置缺失');
    if(adjustments.engine==='spectral'&&adjustments.spectralVersion!==2)throw Error('自动适配需要新版光谱设置');
    return renderFilm({kind:'auto-fit',input:await inputFor(p.path,adjustments),referenceInput:await imageInput(p.path),adjustments,lutPath:adjustments.engine!=='spectral'&&adjustments.lut?lut.path:null});
  });
  ipcMain.handle('film:spectral-preview',async(_,request)=>{
    const p=allowed.get(request?.id);if(!p)throw Error('Unknown photo');
    const adjustments=cleanAdjustments(request.adjustments);adjustments.engine='spectral';
    const result=await renderFilm({kind:'spectral-preview',input:await inputFor(p.path,adjustments),size:400,adjustments});
    return {...result,signature:String(request.signature||'').slice(0,4000)};
  });
  ipcMain.handle('film:preview-lut',async(_,hash)=>{const lut=lutLibrary.resolve(hash);if(!lut)throw Error('胶片配置缺失');const cube=parseCube(await fs.readFile(lut.path,'utf8'));return {size:cube.size,min:cube.min,max:cube.max,data:cube.data};});
  ipcMain.handle('film:import',async()=>{
    const result=await dialog.showOpenDialog(win,{title:'导入胶片色彩配置',properties:['openFile'],filters:[{name:'Cube / HaldCLUT',extensions:['cube','png','tif','tiff']}]});
    return result.canceled?null:lutLibrary.import(result.filePaths[0]);
  });
  const resources={dehancer:'https://www.dehancer.com/shop/desktop',rni:'https://reallyniceimages.com/',dxo:'https://www.dxo.com/en/dxo-filmpack/',spektrafilm:'https://github.com/andreavolpato/spektrafilm'};
  ipcMain.handle('film:resource',async(_,key)=>{if(!Object.hasOwn(resources,key))throw Error('Unknown resource');await shell.openExternal(resources[key]);return true;});
  ipcMain.handle('photos:open-export',async()=>{if(!lastExportFolder)return false;const error=await shell.openPath(lastExportFolder);if(error)throw Error(error);return true;});
  ipcMain.handle('photos:export',async(_,ids,format)=>{
    if(exporting)throw Error('已有导出正在进行');
    const wanted=new Set(Array.isArray(ids)?ids.slice(0,5000):[]),photos=state.photos.filter(p=>wanted.has(p.id)).map(p=>({...p,adjustments:cleanAdjustments(p.adjustments)}));
    if(!photos.length)throw Error('请先添加或选中照片');
    exporting=true;
    try{
      const result=await dialog.showOpenDialog(win,{title:'选择导出位置（将创建独立子文件夹）',properties:['openDirectory','createDirectory']});
      if(result.canceled)return {canceled:true};
      const folder=await fs.mkdtemp(path.join(result.filePaths[0],'LightTable-'));
      let count=0;const errors=[];const type=['png','tiff'].includes(format)?format:'jpeg',ext=type==='jpeg'?'jpg':type==='tiff'?'tif':'png';
      for(let i=0;i<photos.length;i++){
        const p=photos[i],a=p.adjustments,lut=lutLibrary.resolve(a.lutId);
        const basename=path.basename(p.name,path.extname(p.name)).replace(/[<>:"/\\|?*\x00-\x1f]/g,'_').slice(0,100)||'photo';
        const target=path.join(folder,`${String(i+1).padStart(3,'0')}-${basename}.${ext}`);
        try{
          if(type==='tiff'&&p.referenceDeveloped&&!hasEdits(a))await fs.copyFile(p.path,target+'.tmp');
          else{if(a.engine!=='spectral'&&a.lut&&!lut)throw Error('胶片配置缺失');await renderFilm({export:true,input:await inputFor(p.path,a),size:type==='tiff'?0:6000,adjustments:a,lutPath:a.engine!=='spectral'&&a.lut?lut.path:null,output:target+'.tmp',format:type,quality:96});}
          await fs.rename(target+'.tmp',target);count++;
        }
        catch(e){await fs.unlink(target+'.tmp').catch(()=>{});errors.push({name:p.name,error:e.message});}
      }
      await fs.writeFile(path.join(folder,'导出记录.json'),JSON.stringify({version:app.getVersion(),count,errors,maxEdge:type==='tiff'?'original':6000,format:type,colorSpace:type==='tiff'?'ProPhoto RGB':'sRGB',bits:type==='tiff'?16:8},null,2));
      lastExportFolder=folder;
      return {count,failed:errors.length,folder};
    }finally{exporting=false;}
  });
  ipcMain.handle('photos:pick', async (_, folder) => {
    const result = await dialog.showOpenDialog(win, { title: folder ? '选择照片文件夹（包含子文件夹）' : '添加照片', properties: folder ? ['openDirectory'] : ['openFile','multiSelections'], filters: folder ? [] : [{ name: '照片', extensions: ['jpg','jpeg','png','webp','tif','tiff','avif','gif','heic','heif','dng'] }] });
    return result.canceled ? { photos: [], errors: [] } : importPaths(result.filePaths);
  });
  ipcMain.handle('photos:drop', (_, paths) => importPaths(Array.isArray(paths) ? paths.slice(0,5000) : []));
  ipcMain.handle('window:fullscreen', (_, enabled) => { win.setFullScreen(Boolean(enabled)); return true; });
  ipcMain.handle('layout:export', async (_, next) => {
    const result = await dialog.showSaveDialog(win, { title: '导出台面布局', defaultPath: 'dose.lighttable.json', filters: [{ name: '观片台布局', extensions: ['json'] }] });
    if (result.canceled) return false;
    await fs.writeFile(result.filePath, JSON.stringify(cleanState(next), null, 2)); return true;
  });
  ipcMain.handle('layout:open', async () => {
    const result = await dialog.showOpenDialog(win, { title: '打开台面布局', properties: ['openFile'], filters: [{ name: '观片台布局', extensions: ['json'] }] });
    if (result.canceled) return null;
    const stat = await fs.stat(result.filePaths[0]); if (stat.size > 15e6) throw new Error('布局文件过大');
    const next = cleanState(JSON.parse(await fs.readFile(result.filePaths[0], 'utf8')));
    for (const p of next.photos) allowed.set(p.id, p);
    await persist(next); return next;
  });
  ipcMain.handle('layout:new', async () => {
    const result = await dialog.showMessageBox(win, { type: 'question', title: '新建台面', message: '收起当前台面，开始新的观片？', detail: '当前照片列表和布局会备份在本机。照片原文件不会被删除。', buttons: ['取消', '备份并新建'], defaultId: 0, cancelId: 0 });
    if(result.response!==1)return null;
    await writeQueue;
    const backups=path.join(app.getPath('userData'),'backups');await fs.mkdir(backups,{recursive:true});
    await fs.writeFile(path.join(backups,`table-${new Date().toISOString().replace(/[:.]/g,'-')}.json`),JSON.stringify(state,null,2));
    const next=cleanState(null);await persist(next);return next;
  });
  Menu.setApplicationMenu(null);
  win = new BrowserWindow({ width: 1440, height: 960, minWidth: 980, minHeight: 680, backgroundColor: '#171918', title: 'dose', titleBarStyle: 'hidden', titleBarOverlay: {color:'#171918',symbolColor:'#F3F1EB',height:60}, icon: path.join(__dirname,'../assets/icon.png'), show: false, webPreferences: { preload: path.join(__dirname,'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', e => e.preventDefault());
  win.webContents.session.setPermissionRequestHandler((_, __, callback) => callback(false));
  win.once('ready-to-show', () => win.show());
  win.once('closed',()=>referenceEditor.dispose());
  let closing = false;
  win.on('close', e => { if (!closing) { e.preventDefault(); win.webContents.send('before-close'); setTimeout(async () => { if(!await referenceEditor.prepareClose())return;await Promise.all([writeQueue.catch(() => {}),gridWrite?.catch(()=>{})]); closing = true; win.close(); }, 400); } });
  await win.loadFile(path.join(__dirname,'index.html'));
});
app.on('window-all-closed', () => app.quit());

