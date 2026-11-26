const {test}=require('node:test'),assert=require('node:assert/strict');
const {readExif}=require('../src/photo-metadata.cjs');
function fixture(little=true,{date='2026:10:17 12:34:56',zone='+09:00',lat=[35,0,0],lon=[135,46,30],latRef='N',lonRef='E'}={}){
  const b=Buffer.alloc(600),base=6;
  b.write('Exif\0\0',0,'ascii');b.write(little?'II':'MM',base);
  const u16=(p,n)=>little?b.writeUInt16LE(n,base+p):b.writeUInt16BE(n,base+p);
  const u32=(p,n)=>little?b.writeUInt32LE(n,base+p):b.writeUInt32BE(n,base+p);
  function entry(at,tag,type,count,value){u16(at,tag);u16(at+2,type);u32(at+4,count);if(typeof value==='string')b.write(value,base+at+8,'ascii');else u32(at+8,value);}
  u16(2,42);u32(4,8);u16(8,2);entry(10,0x8769,4,1,40);entry(22,0x8825,4,1,80);
  u16(40,2);entry(42,0x9003,2,date.length+1,200);entry(54,0x9011,2,zone.length+1,224);
  b.write(date+'\0',base+200,'ascii');b.write(zone+'\0',base+224,'ascii');
  u16(80,4);entry(82,1,2,2,latRef+'\0');entry(94,2,5,3,240);entry(106,3,2,2,lonRef+'\0');entry(118,4,5,3,264);
  lat.forEach((n,i)=>{u32(240+i*8,n);u32(244+i*8,1);});lon.forEach((n,i)=>{u32(264+i*8,n);u32(268+i*8,1);});
  return {b,u16,u32};
}
for(const little of [true,false])test('EXIF actual timestamp + GPS '+(little?'little':'big')+' endian',()=>{
  const {b}=fixture(little),result=readExif(b);
  assert.equal(result.capturedAt,Date.UTC(2026,9,17,3,34,56));
  assert.deepEqual(result.gps,{latitude:35,longitude:135+46/60+30/3600});
  assert.deepEqual(readExif(b.subarray(6)),result);
});
test('zero and south/west GPS are preserved',()=>{
  assert.deepEqual(readExif(fixture(true,{lat:[0,0,0],lon:[0,0,0]}).b).gps,{latitude:0,longitude:0});
  assert.deepEqual(readExif(fixture(false,{lat:[35,0,0],lon:[135,0,0],latRef:'S',lonRef:'W'}).b).gps,{latitude:-35,longitude:-135});
});
test('invalid timestamps and GPS do not become invented facts',()=>{
  for(const date of ['2026:02:31 12:00:00','2026:13:17 12:00:00','2026:10:17 25:00:00'])assert.equal(readExif(fixture(true,{date}).b).capturedAt,null);
  assert.equal(readExif(fixture(true,{lat:[91,0,0]}).b).gps,null);
  assert.equal(readExif(fixture(true,{lat:[35,60,0]}).b).gps,null);
  assert.equal(readExif(fixture(true,{zone:'+24:00'}).b).capturedAt,null);
});
test('malformed offsets/counts/types fail closed',()=>{
  const broken=fixture();broken.u32(94+8,0xffffff00);assert.equal(readExif(broken.b).gps,null);
  const type=fixture();type.u16(94+2,4);assert.equal(readExif(type.b).gps,null);
  const count=fixture();count.u32(94+4,65539);assert.equal(readExif(count.b).gps,null);
  const root=fixture();root.u32(4,0xffffffff);assert.deepEqual(readExif(root.b),{capturedAt:null,gps:null});
  for(const b of [undefined,Buffer.alloc(5),Buffer.from('Exif\0\0bad')])assert.deepEqual(readExif(b),{capturedAt:null,gps:null});
});
