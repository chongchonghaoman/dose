const {app,BrowserWindow,ipcMain,dialog,shell,protocol,net}=require('electron');
const fs=require('node:fs/promises'),syncFs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {pathToFileURL}=require('node:url');
const {ReferenceHost}=require('./reference-host.cjs');
const extensions=['spektrapair','nef','arw','cr2','cr3','raf','dng','orf','rw2','pef','srw','tif','tiff','jpg','jpeg','png'];
const key=p=>path.resolve(p).toLowerCase();
const hash=p=>crypto.createHash('sha256').update(key(p)).digest('hex');
const supported=p=>extensions.includes(path.extname(p).slice(1).toLowerCase());
const inside=(root,p)=>{const rel=path.relative(root,path.resolve(p));return rel!==''&&!rel.startsWith('..')&&!path.isAbsolute(rel);};
async function readJson(file){try{return JSON.parse(await fs.readFile(file,'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}}
async function writeJson(file,value){await fs.mkdir(path.dirname(file),{recursive:true});const temp=file+'.'+crypto.randomUUID()+'.tmp';await fs.writeFile(temp,JSON.stringify(value,null,2));await fs.rename(temp,file);}
async function entry(file){const stat=await fs.stat(file);return {path:path.resolve(file),name:path.basename(file),size:stat.size,mtime_ms:stat.mtimeMs};}
function createReferenceEditor({getParent,resolvePhoto,prepareInput,importResult}){
  const root=path.join(app.getPath('userData'),'reference-editor');
  const resource=name=>{const packaged=path.join(process.resourcesPath,name);return syncFs.existsSync(packaged)?packaged:path.join(__dirname,'..','native',name);};
  const home=resource('reference'),bundle=resource('reference-editor');
  let window=null,host=null,launchPaths=[],returnDir=null,associations={},opened=new Map(),writes=Promise.resolve(),editorReady=false,closing=false,closePromise=null,resolveClose=null;
  const ready=(async()=>{await fs.mkdir(root,{recursive:true});associations=await readJson(path.join(root,'associations.json'))||{};})();
  const emit=event=>{if(window&&!window.isDestroyed())window.webContents.send('reference:event',event);};
  const trusted=e=>{if(!window||e.sender!==window.webContents)throw Error('无效显影室窗口');};
  const sidecar=p=>path.join(root,'sidecars',hash(p)+'.json');
  const store=(area,name)=>{if(!/^[\w-]+$/.test(area)||!/^[-\w.]+$/.test(name)||name.includes('..'))throw Error('Invalid store name');return path.join(root,'stores',area,name.endsWith('.json')?name:name+'.json');};
  const serialWrite=(file,value)=>{const run=writes.catch(()=>{}).then(()=>writeJson(file,value));writes=run;return run;};
  async function listImages(dir){
    const files=await fs.readdir(dir,{withFileTypes:true});const images=await Promise.all(files.filter(e=>e.isFile()&&!e.name.startsWith('.')&&supported(e.name)).sort((a,b)=>a.name.localeCompare(b.name,undefined,{numeric:true})).map(e=>entry(path.join(dir,e.name))));
    const pairs=path.join(root,'pairs');for(const name of await fs.readdir(pairs).catch(()=>[])){if(!name.endsWith('.spektrapair'))continue;const file=path.join(pairs,name),doc=await readJson(file).catch(()=>null);if(doc?.folder&&key(doc.folder)===key(dir))images.push(await entry(file));}
    return images;
  }
  async function expandPaths(paths){const all=[];for(const p of paths){try{const stat=await fs.stat(p);if(stat.isDirectory())all.push(...await listImages(p));else if(supported(p))all.push(await entry(p));}catch{}}return [...new Map(all.map(e=>[key(e.path),e])).values()];}
  protocol.handle('dose-editor',request=>{const u=new URL(request.url),file=path.resolve(bundle,'.'+decodeURIComponent(u.pathname));if(u.hostname!=='app'||!inside(bundle,file))return new Response('Not found',{status:404});return net.fetch(pathToFileURL(file).href);});
  ipcMain.handle('reference:request',async(e,method,params,options)=>{trusted(e);if(typeof method!=='string'||!/^[a-z_]+$/.test(method))throw Error('Invalid host method');return host.request(method,params,options);});
  ipcMain.on('reference:drop',(e,paths)=>{trusted(e);if(Array.isArray(paths))emit({type:'drop',paths:paths.filter(p=>typeof p==='string').slice(0,5000)});});
  ipcMain.handle('reference:invoke',async(e,op,args=[])=>{
    trusted(e);await ready;const [a,b,c]=args;
    switch(op){
      case 'editorReady':editorReady=true;return;
      case 'closeReady':await writes;closing=true;resolveClose?.(true);setTimeout(()=>{if(window&&!window.isDestroyed())window.close();},50);return;
      case 'closeFailed':resolveClose?.(false);closePromise=null;await dialog.showMessageBox(window,{type:'warning',title:'显影室尚未关闭',message:String(a||'保存设置失败，请重试。')});return;
      case 'state':return host.status();
      case 'restart':host.stop();host=new ReferenceHost(home,emit);return host.status();
      case 'diagnostics':return JSON.stringify({state:host.state,stderr:host.stderr,home},null,2);
      case 'listImages':return listImages(a);
      case 'expandPaths':return expandPaths(a);
      case 'sidecarLoad':return readJson(sidecar(a));
      case 'sidecarSave':await serialWrite(sidecar(a),b);return sidecar(a);
      case 'sidecarPath':return sidecar(a);
      case 'storeRead':return readJson(store(a,b));
      case 'storeWrite':return serialWrite(store(a,b),c);
      case 'pairLoad':return readJson(a);
      case 'pairSave':if(!a.toLowerCase().endsWith('.spektrapair'))throw Error('Invalid pair file');return serialWrite(a,b);
      case 'pairCreate':{const file=path.join(root,'pairs',`Half-Frame Pair ${Date.now()}-${crypto.randomUUID().slice(0,8)}.spektrapair`);await serialWrite(file,{...b,folder:path.resolve(a)});return entry(file);}
      case 'takeLaunchPaths':{const result=launchPaths;launchPaths=[];return result;}
      case 'pathExists':return fs.access(a).then(()=>true,()=>false);
      case 'ensureDir':await fs.mkdir(a,{recursive:true});return;
      case 'appPaths':return {appData:root,sidecars:path.join(root,'sidecars'),logs:path.join(root,'logs'),home:app.getPath('home'),pictures:app.getPath('pictures'),os:'windows',version:'SpektraLab 1.3.1-windows.1 / dose'};
      case 'pickFolder':{const r=await dialog.showOpenDialog(window,{title:a,properties:['openDirectory','createDirectory']});return r.canceled?null:r.filePaths[0];}
      case 'pickFiles':{const r=await dialog.showOpenDialog(window,{title:a,properties:['openFile','multiSelections'],filters:[{name:'Photographs',extensions}]});return r.canceled?[]:r.filePaths;}
      case 'pickSave':{const r=await dialog.showSaveDialog(window,{title:a,defaultPath:b,filters:[{name:c.toUpperCase(),extensions:[c]}]});return r.canceled?null:r.filePath;}
      case 'reveal':shell.showItemInFolder(a);return;
      case 'openUrl':if(!/^https?:\/\//i.test(a))throw Error('Invalid link');await shell.openExternal(a);return;
      case 'message':await dialog.showMessageBox(window,{title:a,message:b,type:c||'info'});return;
      case 'confirm':return (await dialog.showMessageBox(window,{title:a,message:b,type:'question',buttons:['Cancel','OK'],cancelId:0,defaultId:0})).response===1;
      case 'setTitle':window.setTitle('dose 显影室 · '+a);return;
      case 'toggleFullscreen':window.setFullScreen(!window.isFullScreen());return;
      case 'log':await fs.mkdir(path.join(root,'logs'),{recursive:true});await fs.appendFile(path.join(root,'logs','editor.log'),`${new Date().toISOString()} ${a} ${String(b).slice(0,12000)}\n`);return;
      case 'prepareReturn':await fs.mkdir(path.join(root,'results'),{recursive:true});returnDir=await fs.mkdtemp(path.join(root,'results','developed-'));return {path:returnDir};
      case 'completeReturn':{
        if(!returnDir||typeof a!=='string'||!inside(returnDir,a)||!/^\.tiff?$/i.test(path.extname(a)))throw Error('无效显影输出');
        const stat=await fs.stat(a);if(!stat.isFile()||!stat.size)throw Error('显影文件未写入');
        const source=typeof b==='string'?path.resolve(b):null;if(!source)throw Error('缺少显影原片');
        const origin=opened.get(key(source));
        const result=await importResult(a);if(!result.photos.length)throw Error('显影文件返回台面失败：'+result.errors.join(', '));
        Object.assign(result.photos[0],{referenceDeveloped:true,nativeFrame:c?.nativeFrame===true});
        associations[key(a)]={source,original:origin?.original||source};
        await serialWrite(path.join(root,'associations.json'),associations);await writes;
        getParent()?.webContents.send('reference:result',{photo:result.photos[0],sourceIds:origin?.ids||[]});
        returnDir=null;getParent()?.show();getParent()?.focus();window.hide();return {path:a};
      }
      default:throw Error('Unknown editor operation: '+op);
    }
  });
  async function open(ids){
    await ready;const sources=[];opened=new Map();
    for(const id of ids){const p=resolvePhoto(id);if(!p)continue;const assoc=associations[key(p.path)];const source=assoc?.source||await prepareInput(p.path);const original=assoc?.original||p.path;
      sources.push(source);const item=opened.get(key(source));if(item){if(!item.ids.includes(id))item.ids.push(id);}else opened.set(key(source),{original,ids:[id]});}
    if(!sources.length)throw Error('请先在台面选择照片');
    if(window&&!window.isDestroyed()){emit({type:'openPaths',paths:sources});window.show();window.focus();return;}
    if(!syncFs.existsSync(path.join(bundle,'index.html'))||!syncFs.existsSync(path.join(home,'spektralab-host.exe')))throw Error('显影室资源不完整，请解压完整 dose 文件夹。');
    launchPaths=[...new Set(sources)];host=new ReferenceHost(home,emit);
    editorReady=false;closing=false;closePromise=null;
    window=new BrowserWindow({width:1460,height:960,minWidth:1000,minHeight:700,backgroundColor:'#191919',title:'dose 显影室 · SpektraLab',show:false,icon:path.join(__dirname,'../assets/icon.png'),webPreferences:{preload:path.join(__dirname,'reference-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
    window.webContents.setWindowOpenHandler(()=>({action:'deny'}));window.webContents.on('will-navigate',e=>e.preventDefault());
    window.once('ready-to-show',()=>window?.show());
    window.on('close',e=>{if(!closing&&editorReady){e.preventDefault();void prepareClose();}});
    window.on('closed',()=>{host?.stop();host=null;window=null;opened=new Map();});
    await window.loadURL('dose-editor://app/index.html');
  }
  function prepareClose(){if(!window||window.isDestroyed())return Promise.resolve(true);if(!editorReady){window.close();return Promise.resolve(true);}if(!closePromise){closePromise=new Promise(resolve=>{resolveClose=resolve;});emit({type:'close-request'});}return closePromise;}
  function dispose(){host?.stop();if(window&&!window.isDestroyed())window.destroy();}
  app.on('before-quit',dispose);
  return {open,dispose,prepareClose};
}
module.exports={createReferenceEditor};
