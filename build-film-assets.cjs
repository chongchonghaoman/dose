const fs=require('node:fs/promises'),path=require('node:path');
const {haldToCube,hashOf}=require('./src/lut-library.cjs');
(async()=>{
 const dir=path.join(__dirname,'assets/luts'),source=path.join(__dirname,'../clut-source'),meta=JSON.parse((await fs.readFile(path.join(source,'provenance.json'),'utf8')).replace(/^\uFEFF/,''));
 await fs.mkdir(path.join(dir,'source'),{recursive:true});
 const names=['Kodak Portra 400','Fuji 400H','Fuji Superia 400','Fuji Velvia 50','Kodachrome 64','Kodak Tri-X 400'],list=[];
 for(let i=0;i<meta.files.length;i++){
  const original=path.basename(meta.files[i]),file=path.join(source,original),text=await haldToCube(file),hash=hashOf(text);
  await fs.writeFile(path.join(dir,hash+'.cube'),text);await fs.copyFile(file,path.join(dir,'source',original));
  list.push({hash,name:names[i],source:'Pat David · G’MIC',license:'CC BY-SA 4.0',bundled:true,author:'Pat David',sourceUrl:`https://github.com/NatronGitHub/clut/blob/${meta.commit}/${meta.files[i]}`,changes:'Converted 16-bit HaldCLUT to 33³ .cube with trilinear resampling; no creative grading changes.'});
 }
 await fs.writeFile(path.join(dir,'library.json'),JSON.stringify(list,null,2));
 await fs.copyFile(path.join(__dirname,'../clut-README.md'),path.join(dir,'UPSTREAM-README.md'));
 await fs.writeFile(path.join(dir,'NOTICE.md'),'# Film color assets\n\nAuthor: Pat David. Source: https://github.com/NatronGitHub/clut/tree/'+meta.commit+'\n\nLicense: Creative Commons Attribution-ShareAlike 4.0 International — https://creativecommons.org/licenses/by-sa/4.0/\n\nOriginal PNG files are preserved in source/. Converted .cube tables remain CC BY-SA 4.0. Changes: 16-bit HaldCLUT resampled to 33³ RGB cube with trilinear interpolation, no creative changes. The application code has a separate MIT license. Film names describe approximations, not official products or endorsement.\n');
 console.log('Built '+list.length+' attributed film tables');
})().catch(e=>{console.error(e);process.exitCode=1;});
