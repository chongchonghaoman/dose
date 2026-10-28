const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path'),{photoAvailability}=require('../src/photo-availability.cjs');
test('Availability distinguishes readable originals, missing files and directories without modifying records',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'dose-available-')),file=path.join(dir,'test.jpg');await fs.writeFile(file,'fixture');
 const photos=[{id:'a',path:file},{id:'b',path:path.join(dir,'missing.jpg')},{id:'c',path:dir}],before=structuredClone(photos),r=await photoAvailability(photos);
 assert.deepEqual(r,{available:['a'],unavailable:['b','c']});assert.deepEqual(photos,before);assert.equal(await fs.readFile(file,'utf8'),'fixture');
});
test('Availability metadata checks remain bounded and retain input order',async()=>{
 let running=0,max=0;const photos=Array.from({length:100},(_,i)=>({id:'p'+i,path:String(i)}));
 const r=await photoAvailability(photos,async file=>{running++;max=Math.max(max,running);await new Promise(r=>setTimeout(r,1));running--;return Number(file)%2===0;});
 assert(max<=16);assert.deepEqual(r.available,photos.filter((_,i)=>i%2===0).map(p=>p.id));assert.equal(r.unavailable.length,50);
});
test('No unavailable originals are reported as usable and empty libraries stay empty',async()=>{
 assert.deepEqual(await photoAvailability([]),{available:[],unavailable:[]});assert.deepEqual(await photoAvailability([{id:'a',path:'x'}],async()=>{throw Error('denied');}),{available:[],unavailable:['a']});
});
