// SpektraLab's unmodified Windows release host, with its binary stdio protocol.
const {spawn}=require('node:child_process');
const path=require('node:path');
class ReferenceHost {
  constructor(home,onEvent=()=>{}){this.home=home;this.onEvent=onEvent;this.pending=new Map();this.next=0;this.resetBuffer();this.stderr='';this.child=null;this.state={phase:'starting'};}
  resetBuffer(){this.chunks=[];this.buffered=0;this.frame=null;}
  start(){
    if(this.child)return;
    this.resetBuffer();
    const child=this.child=spawn(path.join(this.home,'spektralab-host.exe'),['--resources',path.join(this.home,'host','engine'),'--log-level','error'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    child.stdout.on('data',data=>this.receive(data));
    child.stderr.on('data',data=>{this.stderr=(this.stderr+data.toString()).slice(-12000);});
    child.stdin.on('error',e=>{if(this.child===child)this.stop(e);});
    child.on('error',e=>{if(this.child===child)this.stop(e);});
    child.on('exit',(code,signal)=>{if(this.child===child)this.stop(Error(`SpektraLab 引擎退出 (${code??signal}) ${this.stderr}`));});
  }
  stop(error=Error('显影室已关闭')){
    const child=this.child;this.child=null;child?.kill();
    for(const p of this.pending.values())p.reject(error);this.pending.clear();this.resetBuffer();
    this.state={phase:'failed',reason:error.message};this.onEvent({type:'state',state:this.state});
  }
  receive(data){
    this.chunks.push(data);this.buffered+=data.length;
    while(true){
      if(!this.frame){if(this.buffered<8)return;const prefix=this.take(8);this.frame={h:prefix.readUInt32LE(0),n:prefix.readUInt32LE(4)};}
      const {h,n}=this.frame;
      if(h>16*1024*1024||n>1024*1024*1024){this.stop(Error('显影引擎返回无效长度'));return;}
      if(this.buffered<h+n)return;
      let msg;try{msg=JSON.parse(this.take(h).toString());}catch{this.stop(Error('显影引擎协议错误'));return;}
      const payload=this.take(n);this.frame=null;
      if(msg.id==null){this.onEvent(msg);continue;}
      const pending=this.pending.get(msg.id);if(!pending)continue;this.pending.delete(msg.id);
      if(!msg.ok)pending.reject(Object.assign(Error(msg.error?.message||'显影失败'),{code:msg.error?.code}));
      else{if(pending.method==='hello'){this.state={phase:'ready',hello:msg.result};this.onEvent({type:'state',state:this.state});}pending.resolve({result:msg.result||{},payload});}
    }
  }
  take(n){
    if(!n)return Buffer.alloc(0);this.buffered-=n;
    if(this.chunks[0].length>=n){const result=this.chunks[0].subarray(0,n);if(this.chunks[0].length===n)this.chunks.shift();else this.chunks[0]=this.chunks[0].subarray(n);return result;}
    const result=Buffer.allocUnsafe(n);let offset=0;
    while(offset<n){const chunk=this.chunks[0],count=Math.min(chunk.length,n-offset);chunk.copy(result,offset,0,count);offset+=count;if(count===chunk.length)this.chunks.shift();else this.chunks[0]=chunk.subarray(count);}
    return result;
  }
  request(method,params={},options={}){
    this.start();const id=++this.next,header=Buffer.from(JSON.stringify({id,method,params})),payload=options.payload?Buffer.from(options.payload):Buffer.alloc(0);
    const frame=Buffer.alloc(8+header.length+payload.length);frame.writeUInt32LE(header.length,0);frame.writeUInt32LE(payload.length,4);header.copy(frame,8);payload.copy(frame,8+header.length);
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>this.stop(Error(`显影引擎 ${method} 超时`)),Math.min(600000,Math.max(1000,options.timeoutMs||180000)));
      this.pending.set(id,{method,resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});
      this.child.stdin.write(frame);
    });
  }
  async status(){if(this.state.phase!=='ready')await this.request('hello');return this.state;}
}
module.exports={ReferenceHost};
