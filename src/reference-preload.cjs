const {contextBridge,ipcRenderer,webUtils}=require('electron');
const listen=(name,fn)=>{const listener=(_,value)=>fn(value);ipcRenderer.on(name,listener);return()=>ipcRenderer.removeListener(name,listener);};
contextBridge.exposeInMainWorld('doseEditor',{
  invoke:(op,args=[])=>ipcRenderer.invoke('reference:invoke',op,args),
  request:(method,params={},options={})=>ipcRenderer.invoke('reference:request',method,params,options),
  onEvent:fn=>listen('reference:event',fn),
  onState:fn=>listen('reference:event',event=>{if(event.type==='state')fn(event.state);})
});
window.addEventListener('dragover',e=>e.preventDefault());
window.addEventListener('drop',e=>{e.preventDefault();const paths=[...e.dataTransfer.files].map(f=>webUtils.getPathForFile(f)).filter(Boolean);if(paths.length)ipcRenderer.send('reference:drop',paths);});
