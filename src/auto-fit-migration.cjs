const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto');
function hasLegacyAutoFit(state){return Array.isArray(state?.photos)&&state.photos.some(p=>p?.adjustments?.autoFitMode==='natural'&&p.adjustments.autoFitVersion!==2);}
async function backupLegacyAutoFit(stateFile,bytes){
  const directory=path.join(path.dirname(stateFile),'backups');await fs.mkdir(directory,{recursive:true});
  const target=path.join(directory,'table-before-auto-fit-v2-'+Date.now()+'-'+crypto.randomUUID()+'.json');
  await fs.writeFile(target,bytes,{flag:'wx'});return target;
}
module.exports={hasLegacyAutoFit,backupLegacyAutoFit};
