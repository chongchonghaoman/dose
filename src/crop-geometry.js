(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoseCrop=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  const clamp=(n,lo,hi)=>Math.max(lo,Math.min(hi,n));
  function sourceRect(iw,ih,width,height,crop={}){
    if(![iw,ih,width,height].every(n=>Number.isFinite(n)&&n>0))throw new RangeError('Invalid crop dimensions');
    const zoom=clamp(Number.isFinite(crop.zoom)?crop.zoom:1,1,4),scale=Math.max(width/iw,height/ih)*zoom;
    const sw=Math.min(iw,width/scale),sh=Math.min(ih,height/scale);
    return {x:(iw-sw)*clamp(Number.isFinite(crop.x)?crop.x:.5,0,1),y:(ih-sh)*clamp(Number.isFinite(crop.y)?crop.y:.5,0,1),width:sw,height:sh,scale};
  }
  return {sourceRect};
});
