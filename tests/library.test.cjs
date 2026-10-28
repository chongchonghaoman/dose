const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path'),os=require('node:os'),sharp=require('sharp');
const {LutLibrary,haldToCube}=require('../src/lut-library.cjs'),{parseCube,sampleCube}=require('../src/film.cjs');
test('Hald identity preserves RGB ordering within source quantization',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'lighttable-hald-'));try{
 const data=Buffer.alloc(8*8*3);for(let i=0;i<64;i++){data[i*3]=(i%4)*85;data[i*3+1]=(Math.floor(i/4)%4)*85;data[i*3+2]=Math.floor(i/16)*85;}
 const file=path.join(dir,'identity.png');await sharp(data,{raw:{width:8,height:8,channels:3}}).png().toFile(file);
 const cube=parseCube(await haldToCube(file)),out=[];sampleCube(cube,.2,.5,.8,out);out.forEach((v,k)=>assert(Math.abs(v-[.2,.5,.8][k])<1/255));
 await sharp({create:{width:9,height:9,channels:3,background:'white'}}).png().toFile(path.join(dir,'bad.png'));await assert.rejects(haldToCube(path.join(dir,'bad.png')));
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
test('Bundled library is attributed, integrity-checked, and explicit missing IDs never fall back',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'lighttable-library-'));try{
 const lib=new LutLibrary(dir,path.resolve(__dirname,'../assets/luts'));await lib.load();assert.equal(lib.status().library.length,6);assert(lib.status().library.every(e=>e.license==='CC BY-SA 4.0'&&e.source.includes('Pat David')));assert.equal(lib.resolve('f'.repeat(64)),null);assert(lib.resolve(''));
 const loaded=new LutLibrary(dir,path.resolve(__dirname,'../assets/luts'));await loaded.load();assert.equal(loaded.active,lib.active);
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
