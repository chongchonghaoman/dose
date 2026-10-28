const sharp=require('sharp');
const path=require('node:path');
const fs=require('node:fs/promises');
async function makeFixtures(dir){
  await fs.mkdir(dir,{recursive:true});
  const colors=['#a88e61','#6c8994','#89976c','#9a6851','#696f8c','#4a7e65'];
  for(let k=0;k<6;k++){
    const w=k===4?1200:1800,h=k===4?1800:1200;
    const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="${colors[k]}"/><stop offset="1" stop-color="#17291c"/></linearGradient></defs><rect width="100%" height="100%" fill="url(#g)"/><circle cx="${w*.6}" cy="${h*.35}" r="${w*.17}" fill="#f4e9bc"/><path d="M0 ${h} L${w*.35} ${h*.35} L${w*.6} ${h*.8} L${w} ${h*.5} V${h}Z" fill="#263f34"/><text x="80" y="120" font-family="sans-serif" font-size="58" fill="white">LIGHTTABLE TEST ${k+1}</text></svg>`;
    await sharp(Buffer.from(svg)).jpeg().toFile(path.join(dir,`test-${k+1}.jpg`));
  }
}
module.exports=makeFixtures;
if(require.main===module)makeFixtures(path.join(__dirname,'fixtures'));
