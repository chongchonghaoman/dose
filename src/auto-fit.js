(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.DoseAutoFit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  var W = [.2126, .7152, .0722];
  function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
  function finite(x, d) { return Number.isFinite(x) ? x : d; }
  function quantile(a, q) { if (!a.length) return 0; var i=(a.length-1)*q, lo=Math.floor(i), h=i-lo; return a[lo]+(a[Math.min(lo+1,a.length-1)]-a[lo])*h; }
  function measure(data, channels) {
    channels = channels === 3 ? 3 : 4;
    var n = data && data.length ? Math.floor(data.length / channels) : 0, ys=[], cs=[], sum=0, sumC=0, valid=0, clipped=0;
    var is8 = !!(data && (data instanceof Uint8Array || (typeof Uint8ClampedArray !== 'undefined' && data instanceof Uint8ClampedArray) || (typeof Buffer !== 'undefined' && Buffer.isBuffer(data))));
    if (!is8 && data && n) { for (var q=0;q<Math.min(data.length,n*channels);q++) if (finite(data[q],0)>1) { is8=true; break; } }
    function lin(v) { return v <= .04045 ? v/12.92 : Math.pow((v+.055)/1.055,2.4); }
    for (var i=0;i<n;i++) {
      var r=finite(data[i*channels],0), g=finite(data[i*channels+1],0), b=finite(data[i*channels+2],0);
      if (is8) { r/=255; g/=255; b/=255; }
      r=clamp(r,0,1); g=clamp(g,0,1); b=clamp(b,0,1);
      var er=r, eg=g, eb=b, y=W[0]*lin(r)+W[1]*lin(g)+W[2]*lin(b), mx=Math.max(er,eg,eb), mn=Math.min(er,eg,eb), c=mx-mn;
      // Keep all finite pixels in luma order statistics so source/styled use one population.
      ys.push(y);
      // Retain coloured shadows: otherwise bright grey skies can hide strongly
      // saturated foliage from the colour statistic after a film conversion.
      if (y>.003 && y<.995 && c>.015 && mx>.04) cs.push(c/Math.max(mx,1e-6));
      if (y<=0.012 || y>=0.995) { clipped += (y>=0.995?1:0); continue; }
      sum+=y; sumC+=c/Math.max(y,1e-6); valid++;
    }
    ys.sort(function(a,b){return a-b;}); cs.sort(function(a,b){return a-b;});
    var lo=quantile(ys,.08), hi=quantile(ys,.92), mid=quantile(ys,.5);
    var chroma=cs.length?quantile(cs,.75):0;
    return {count:n, valid:valid, mean:valid?sum/valid:0, median:mid, p02:quantile(ys,.02),p10:quantile(ys,.1),p25:quantile(ys,.25),p50:mid,p75:quantile(ys,.75),p90:quantile(ys,.9),p98:quantile(ys,.98),p08:lo, p92:hi,
      luminance:mid, chroma:chroma, saturation:chroma, clipped:clipped, lowSignal:n-valid, finite:true};
  }
  function correctLinear(r,g,b,ev,sat,weights) {
    r=clamp(finite(r,0),0,1); g=clamp(finite(g,0),0,1); b=clamp(finite(b,0),0,1);
    ev=finite(ev,0); sat=finite(sat,1); weights=weights||W;
    if (ev===0 && sat===1) return [r,g,b];
    var Y=weights[0]*r+weights[1]*g+weights[2]*b, gain=Math.pow(2,ev);
    var Ynew=Y*gain/(1+(gain-1)*Y), ratio=Ynew/Math.max(Y,1e-8);
    var d0=(r*ratio-Ynew)*sat, d1=(g*ratio-Ynew)*sat, d2=(b*ratio-Ynew)*sat;
    var scale=1;
    function bound(v,d) { if (d>0) return (1-v)/d; if (d<0) return -v/d; return 1; }
    scale=Math.min(scale,bound(Ynew,d0),bound(Ynew,d1),bound(Ynew,d2)); scale=clamp(scale,0,1);
    return [clamp(Ynew+d0*scale,0,1),clamp(Ynew+d1*scale,0,1),clamp(Ynew+d2*scale,0,1)];
  }
  function derive(sourceData, styledData, channels) {
    var source=measure(sourceData,channels), styled=measure(styledData,channels);
    var result={ev:0,saturation:1,source:source,styled:styled,version:2};
    // An already metered film must never be pulled down to a dark original.
    // Preserve low-key/night intent and require agreement across tonal ranges.
    if(!source.valid||!styled.valid||source.p50<.035||source.p75<.12)return result;
    var votes=[];
    ['p25','p50','p75'].forEach(function(k){
      if(source[k]>.012&&styled[k]>.002)votes.push(Math.log(source[k]/styled[k])/Math.LN2);
    });
    if(votes.filter(function(v){return v>.35;}).length<2)return result;
    votes.sort(function(a,b){return a-b;});
    var ev=clamp(quantile(votes,.5)*.4,0,.75);
    if(ev>=.12)result.ev=ev;
    return result;
  }
  function safeBrightness(before,after){
    var mid=before.p75-before.p25,shadow=before.p50-before.p10;
    return after.p25>=before.p25-.002&&after.p50>=before.p50-.002&&after.p75>=before.p75-.002&&
      after.p75-after.p25>=mid*.97-.002&&after.p50-after.p10>=shadow*.98-.002&&
      after.clipped<=before.clipped+Math.max(1,before.count*.0001);
  }
  return {measure:measure, derive:derive, correctLinear:correctLinear,safeBrightness:safeBrightness};
});
