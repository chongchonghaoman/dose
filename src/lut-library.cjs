const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto'),sharp=require('sharp');
const {parseCube,sampleCube}=require('./film.cjs');
const hashOf=text=>crypto.createHash('sha256').update(text).digest('hex');
const validHash=h=>typeof h==='string'&&/^[a-f0-9]{64}$/.test(h);
const SHOWCASE='3a1bf3689442daafbafc5da558a41cef6da7fe5e1bb7b89687884aeb23645324';
async function haldToCube(file){
  const {data,info}=await sharp(file,{limitInputPixels:17000000}).toColourspace('rgb16').removeAlpha().raw({depth:'ushort'}).toBuffer({resolveWithObject:true});
  const level=Math.round(Math.cbrt(info.width));
  if(info.width!==info.height||level<2||level>16||level**3!==info.width||info.channels!==3)throw Error('不是有效 HaldCLUT：需要边长为 level³ 的方形 PNG/TIFF');
  const samples=new Float32Array(data.length/2),little=require('node:os').endianness()==='LE';for(let i=0;i<samples.length;i++)samples[i]=(little?data.readUInt16LE(i*2):data.readUInt16BE(i*2))/65535;
  const n=level**2,cube={size:n,min:[0,0,0],max:[1,1,1],data:samples},size=Math.min(n,33),out=[0,0,0];
  const rows=['# Converted from sRGB HaldCLUT by LightTable; R-fastest order',`LUT_3D_SIZE ${size}`];
  for(let b=0;b<size;b++)for(let g=0;g<size;g++)for(let r=0;r<size;r++){sampleCube(cube,r/(size-1),g/(size-1),b/(size-1),out);rows.push(out.map(v=>v.toFixed(7)).join(' '));}
  return rows.join('\n')+'\n';
}
class LutLibrary{
  constructor(dir,bundledDir){this.dir=dir;this.bundledDir=bundledDir;this.entries=new Map();this.active='';}
  async load(){
    await fs.mkdir(this.dir,{recursive:true});
    for(const [dir,bundled] of [[this.bundledDir,true],[this.dir,false]]){
      let list=[];try{list=JSON.parse(await fs.readFile(path.join(dir,'library.json'),'utf8'));}catch{}
      if(!Array.isArray(list))continue;
      for(const meta of list.slice(0,500)){if(!validHash(meta.hash))continue;try{
        const file=path.join(dir,meta.hash+'.cube'),text=await fs.readFile(file,'utf8');if(hashOf(text)!==meta.hash)continue;parseCube(text);
        this.entries.set(meta.hash,{hash:meta.hash,name:String(meta.name||'自定义胶片').slice(0,100),source:String(meta.source||'本地导入').slice(0,160),license:String(meta.license||'用户提供').slice(0,160),bundled,path:file});
      }catch{}}
    }
    try{
      const meta=JSON.parse(await fs.readFile(path.join(this.dir,'active.json'),'utf8'));
      if(validHash(meta.hash)){
        if(!this.entries.has(meta.hash)){const file=path.join(this.dir,meta.hash+'.cube'),text=await fs.readFile(file,'utf8');if(hashOf(text)===meta.hash){parseCube(text);this.entries.set(meta.hash,{hash:meta.hash,path:file,name:meta.hash===SHOWCASE?'英泽君5207 · 官网展示版':String(meta.name||'旧版本地配置'),source:'本地导入',license:'保留原作者权利',bundled:false});}}
        if(this.entries.has(meta.hash))this.active=meta.hash;
      }
    }catch{}
    if(!this.active)this.active=this.entries.keys().next().value||'';
    await this.save();return this.status();
  }
  async save(){const entries=[...this.entries.values()].filter(e=>!e.bundled).map(({path,...m})=>m);await fs.writeFile(path.join(this.dir,'library.json'),JSON.stringify(entries,null,2));if(this.active)await fs.writeFile(path.join(this.dir,'active.json'),JSON.stringify({hash:this.active,name:this.entries.get(this.active)?.name}));}
  resolve(id){return this.entries.get(id||this.active)||null;}
  status(){const e=this.resolve('');return {available:!!e,name:e?.name||'',hash:e?.hash||'',library:[...this.entries.values()].map(({path,...m})=>m)};}
  async import(file){
    const stat=await fs.stat(file);if(stat.size>64e6)throw Error('LUT 文件超过 64 MB');
    const ext=path.extname(file).toLowerCase();if(!['.cube','.png','.tif','.tiff'].includes(ext))throw Error('支持 .cube 或 HaldCLUT PNG/TIFF');
    const text=ext==='.cube'?await fs.readFile(file,'utf8'):await haldToCube(file);parseCube(text);const hash=hashOf(text);
    if(!this.entries.has(hash)){const target=path.join(this.dir,hash+'.cube');await fs.writeFile(target,text);this.entries.set(hash,{hash,path:target,name:hash===SHOWCASE?'英泽君5207 · 官网展示版':path.basename(file,ext).slice(0,100),source:ext==='.cube'?'本地导入':'HaldCLUT 导入',license:'用户提供 · 请保留原文件授权',bundled:false});}
    this.active=hash;await this.save();return this.status();
  }
}
module.exports={LutLibrary,haldToCube,hashOf};
