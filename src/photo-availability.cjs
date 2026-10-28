const fs=require('node:fs/promises'),{constants}=require('node:fs');
async function readableFile(file){await fs.access(file,constants.R_OK);return (await fs.stat(file)).isFile();}
async function photoAvailability(photos,probe=readableFile){
 const records=photos.slice(0,5000),usable=new Array(records.length);let cursor=0;
 await Promise.all(Array.from({length:Math.min(16,records.length)},async()=>{while(cursor<records.length){const index=cursor++;try{usable[index]=Boolean(await probe(records[index].path));}catch{usable[index]=false;}}}));
 return {available:records.filter((_,i)=>usable[i]).map(p=>p.id),unavailable:records.filter((_,i)=>!usable[i]).map(p=>p.id)};
}
module.exports={photoAvailability};
