const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto');
const isHeic=file=>/\.(heic|heif)$/i.test(file);
function createHeicCache(directory,render){
  const jobs=new Map();
  return async file=>{
    if(!isHeic(file))return file;
    const stat=await fs.stat(file);
    if(stat.size>256*1024*1024)throw Error('HEIC 文件超过 256 MB');
    const hash=crypto.createHash('sha256').update(`heic-v1:${file}:${stat.size}:${stat.mtimeMs}`).digest('hex');
    const output=path.join(directory,hash+'.png');
    try{await fs.access(output);return output}catch{}
    if(!jobs.has(output))jobs.set(output,(async()=>{
      await fs.mkdir(directory,{recursive:true});
      try{await render({kind:'decode-heic',input:file,output:output+'.tmp'});await fs.rename(output+'.tmp',output);return output}
      catch(e){await fs.unlink(output+'.tmp').catch(()=>{});throw e}
    })().finally(()=>jobs.delete(output)));
    return jobs.get(output);
  };
}
async function decodeHeic(input,output){
  const decode=require('heic-decode'),sharp=require('sharp');
  const images=await decode.all({buffer:await fs.readFile(input)});
  try{
    const first=images[0];
    if(!first||first.width*first.height>60000000)throw Error('HEIC 图像为空或超过 6000 万像素');
    const {width,height,data}=await first.decode();
    await sharp(Buffer.from(data.buffer,data.byteOffset,data.byteLength),{raw:{width,height,channels:4}}).png().toFile(output);
  }finally{images.dispose()}
}
module.exports={isHeic,createHeicCache,decodeHeic};
