const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto');
const isDng=file=>/\.dng$/i.test(file);
function createDngCache(directory,render){
  const jobs=new Map();
  return async file=>{
    if(!isDng(file))return file;
    const stat=await fs.stat(file);if(stat.size>512*1024*1024)throw Error('DNG 文件超过 512 MB');
    const key=crypto.createHash('sha256').update(`dng-libraw0222-v2:${file}:${stat.size}:${stat.mtimeMs}`).digest('hex'),output=path.join(directory,key+'.png');
    try{await fs.access(output);return output;}catch{}
    if(!jobs.has(output))jobs.set(output,(async()=>{
      await fs.mkdir(directory,{recursive:true});
      try{await render({kind:'decode-dng',input:file,output:output+'.tmp'});await fs.rename(output+'.tmp',output);return output;}
      catch(e){await fs.unlink(output+'.tmp').catch(()=>{});throw Error('DNG 解码失败：'+e.message);}
    })().finally(()=>jobs.delete(output)));
    return jobs.get(output);
  };
}
module.exports={isDng,createDngCache};
