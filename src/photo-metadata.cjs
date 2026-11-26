const fs=require('node:fs/promises');
const missing=()=>({capturedAt:null,gps:null});
function readExif(buffer){
  const result=missing();
  if(!Buffer.isBuffer(buffer))return result;
  const base=buffer.toString('ascii',0,6)==='Exif\0\0'?6:0;
  if(buffer.length<base+8)return result;
  const order=buffer.toString('ascii',base,base+2);
  if(!['II','MM'].includes(order))return result;
  const le=order==='II',inside=(p,n)=>Number.isInteger(p)&&p>=base&&n>=0&&p+n<=buffer.length;
  const u16=p=>inside(p,2)?(le?buffer.readUInt16LE(p):buffer.readUInt16BE(p)):null;
  const u32=p=>inside(p,4)?(le?buffer.readUInt32LE(p):buffer.readUInt32BE(p)):null;
  if(u16(base+2)!==42)return result;
  function ifd(offset){
    if(!Number.isInteger(offset)||offset<8)return null;
    const start=base+offset,count=u16(start);
    if(count===null||count>4096||!inside(start+2,count*12))return null;
    const entries=new Map();
    for(let k=0;k<count;k++){const at=start+2+k*12;entries.set(u16(at),{at,type:u16(at+2),count:u32(at+4)});}
    return entries;
  }
  function data(entry,type,count){
    if(!entry||entry.type!==type||!Number.isInteger(entry.count)||entry.count<1||entry.count>65536||count!==undefined&&entry.count!==count)return null;
    const sizes={2:1,4:4,5:8},bytes=entry.count*sizes[type];
    if(!bytes)return null;
    const offset=bytes<=4?entry.at+8:base+u32(entry.at+8);
    return inside(offset,bytes)?offset:null;
  }
  function text(entry){
    const at=data(entry,2);return at===null?null:buffer.toString('ascii',at,at+entry.count).split('\0')[0].trim();
  }
  function child(entry){const at=data(entry,4,1);return at===null?null:ifd(u32(at));}
  const root=ifd(u32(base+4));if(!root)return result;
  const exif=child(root.get(0x8769)),date=text(exif?.get(0x9003));
  const match=/^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(date||'');
  if(match){
    const [year,month,day,hour,minute,second]=match.slice(1).map(Number);
    const value=Date.UTC(year,month-1,day,hour,minute,second),d=new Date(value);
    if(year>=1900&&year<=9999&&month>=1&&month<=12&&day>=1&&day<=31&&hour<24&&minute<60&&second<60&&d.getUTCFullYear()===year&&d.getUTCMonth()===month-1&&d.getUTCDate()===day){
      const zone=text(exif?.get(0x9011)),z=/^([+-])(\d{2}):(\d{2})$/.exec(zone||'');
      if(!zone||z&&Number(z[2])<=14&&Number(z[3])<60){
        const offset=z?(z[1]==='+'?1:-1)*(Number(z[2])*60+Number(z[3]))*60000:0;
        result.capturedAt=value-offset;
      }
    }
  }
  const gps=child(root.get(0x8825));
  function coordinate(tag,refTag,limit,positive,negative){
    const at=data(gps?.get(tag),5,3),ref=text(gps?.get(refTag));
    if(at===null||![positive,negative].includes(ref))return null;
    const values=[];
    for(let k=0;k<3;k++){const n=u32(at+k*8),den=u32(at+k*8+4);if(n===null||!den)return null;values.push(n/den);}
    if(values[1]>=60||values[2]>=60)return null;
    const number=values[0]+values[1]/60+values[2]/3600;
    return number<=limit?number*(ref===negative?-1:1):null;
  }
  const latitude=coordinate(2,1,90,'N','S'),longitude=coordinate(4,3,180,'E','W');
  if(latitude!==null&&longitude!==null)result.gps={latitude,longitude};
  return result;
}
function createPhotoMetadata({resolvePhoto,sharp,imageInput}){
  const cache=new Map(),queue=[];let active=0;
  function pump(){
    while(active<4&&queue.length){const job=queue.shift();active++;Promise.resolve().then(job.fn).then(job.resolve,job.reject).finally(()=>{active--;pump();});}
  }
  const limited=fn=>new Promise((resolve,reject)=>{queue.push({fn,resolve,reject});pump();});
  async function read(id){
    const photo=resolvePhoto(id);if(!photo)return {id,...missing(),error:'Unknown photo'};
    try{
      const stat=await fs.stat(photo.path),key=JSON.stringify([photo.path,stat.size,stat.mtimeMs]);
      if(!cache.has(key)){
        const job=limited(async()=>{let meta;try{meta=await sharp(photo.path).metadata();}catch{meta=await sharp(await imageInput(photo.path)).metadata();}return readExif(meta.exif);});
        cache.set(key,job);job.catch(()=>{if(cache.get(key)===job)cache.delete(key);});
        if(cache.size>5000)cache.delete(cache.keys().next().value);
      }
      return {id,...await cache.get(key)};
    }catch(error){return {id,...missing(),error:error.message||'Metadata unavailable'};}
  }
  return async ids=>{
    const requests=[...new Set((Array.isArray(ids)?ids:[]).slice(0,5000).filter(id=>typeof id==='string'))],out=new Array(requests.length);
    let cursor=0;await Promise.all(Array.from({length:Math.min(4,requests.length)},async()=>{while(cursor<requests.length){const at=cursor++;out[at]=await read(requests[at]);}}));
    return out;
  };
}
module.exports={readExif,createPhotoMetadata};
