const fs=require('node:fs/promises'),path=require('node:path');
const {LutLibrary}=require('./src/lut-library.cjs');
(async()=>{
 const dir=process.argv[2]||path.join(process.env.APPDATA,'lighttable-windows/luts');
 const lib=new LutLibrary(dir,path.join(__dirname,'assets/luts'));await lib.load();const active=lib.active;
 const root=path.join(__dirname,'../spektrafilm-generated');
 const entries=[['spektrafilm_v034_portra400_portraendura_1lut_srgb_srgb','lut_v034_portra400_portraendura.cube','Portra 400 / Endura'],['spektrafilm_v034_portra160_endurapremier_1lut_srgb_srgb','lut_v034_portra160_endurapremier.cube','Portra 160 / Endura Premier'],['spektrafilm_v034_pro400h_crystalarchive_1lut_srgb_srgb','lut_v034_pro400h_crystalarchive.cube','Pro 400H / Crystal Archive']];
 for(const [folder,file,name] of entries){const result=await lib.import(path.join(root,folder,file));const e=lib.resolve(result.hash);e.name=name;e.source='spektrafilm 0.3.4 · 本机生成';e.license='Andrea Volpato · CC BY-SA 4.0';}
 lib.active=active;await lib.save();
 await fs.copyFile(path.join(root,'SPEKTRAFILM_LICENSE.txt'),path.join(dir,'SPEKTRAFILM_LICENSE.txt'));
 await fs.copyFile(path.join(root,'PROVENANCE.md'),path.join(dir,'SPEKTRAFILM-PROVENANCE.md'));
 console.log(JSON.stringify({total:lib.status().library.length,localSpectral:3,activePreserved:lib.active===active}));
})().catch(e=>{console.error(e);process.exitCode=1;});
