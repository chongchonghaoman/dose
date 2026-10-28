// Independent .cube reader and image controls. No proprietary LUT is bundled.
const autoFitMath = typeof module === 'object' && module.exports ? require('./auto-fit.js') : globalThis.DoseAutoFit;
const DEFAULTS = Object.freeze({ engine: 'lut', spectralFilm: 'kodak_portra_400', spectralPaper: 'kodak_portra_endura', filmFormat: 35, printExposure: 0, spectralEdge:false, spectralDate:false, spectralDateText:'', spectralMask:false, spectralMaskHighlights:0, spectralMaskShadows:0, lut: false, lutId: '', strength: 100, exposure: 0, highlights: 0, shadows: 0, contrast: 0, temperature: 0, saturation: 0, grain: 0, halation: 0, bloom: 0, autoFitMode:'off',autoFitVersion:2,autoFitEV:0,autoFitSaturation:1,autoFitKey:'' });
// Version is explicit: unversioned saved spectral recipes retain v0.9 behavior.
const SPECTRAL_DEFAULTS = Object.freeze({ ...DEFAULTS, engine:'spectral', spectralVersion:2, metering:'balanced', spectralPaper:'kodak_supra_endura', grain:50, halation:25, bloom:10/3 });
function spectralDefaults() { return { ...SPECTRAL_DEFAULTS }; }
// Saved recipes without an intent keep the original product parameters.
// Natural is an explicit, versioned recipe choice, never an upgrade migration.
const NATURAL_SPECTRAL_DEFAULTS = Object.freeze({ ...SPECTRAL_DEFAULTS, spectralIntent:'natural', metering:'manual', grain:12, halation:5, bloom:0 });
function naturalDefaults() { return { ...NATURAL_SPECTRAL_DEFAULTS }; }
function withLut(adjustments,id){
  const base=adjustments?.engine==='spectral'?DEFAULTS:adjustments;
  return {...DEFAULTS,...base,engine:'lut',lut:!!id,lutId:id||'',autoFitMode:'off',autoFitVersion:2,autoFitEV:0,autoFitSaturation:1,autoFitKey:''};
}
function withSpectralIntent(a,intent) {
  const natural=intent==='natural',old=a.spectralIntent==='natural'?NATURAL_SPECTRAL_DEFAULTS:SPECTRAL_DEFAULTS;
  const defaults=natural?NATURAL_SPECTRAL_DEFAULTS:SPECTRAL_DEFAULTS;
  const next={...a,engine:'spectral',spectralVersion:2,spectralIntent:natural?'natural':'original',metering:defaults.metering,autoFitMode:'off',autoFitEV:0,autoFitKey:''};
  for(const key of ['grain','halation','bloom'])if(a[key]===old[key]||a[key]==null)next[key]=defaults[key];
  return next;
}
function withSpectralFilm(adjustments,id,films){
  const next={...adjustments,spectralFilm:id},film=films.find(f=>f.id===id);
  // Original Session.selectFilmStock: use the declared print material when
  // explicitly choosing a negative. Opening an existing recipe keeps its pair.
  if(next.spectralVersion===2&&film?.targetPrint)next.spectralPaper=film.targetPrint;
  return next;
}
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
function cleanAdjustments(input = {}) {
  const result = { ...DEFAULTS, lut: input?.lut === true, lutId: typeof input?.lutId === 'string' && /^[a-f0-9]{64}$/.test(input.lutId) ? input.lutId : '' };
  result.engine = input?.engine === 'spectral' ? 'spectral' : 'lut';
  result.spectralVersion = input?.spectralVersion === 2 ? 2 : 1;
  result.spectralIntent = result.spectralVersion===2&&input?.spectralIntent==='natural'?'natural':'original';
  result.metering = ['balanced','center','protect_highlights','protect_shadows','manual'].includes(input?.metering) ? input.metering : 'balanced';
  result.autoFitVersion=2;
  result.autoFitMode=result.engine==='spectral'&&result.spectralIntent==='natural'?'off':input?.autoFitMode==='natural'&&input?.autoFitVersion===2?'natural':'off';
  result.autoFitEV=result.autoFitMode==='natural'&&typeof input?.autoFitEV==='number'&&Number.isFinite(input.autoFitEV)?clamp(input.autoFitEV,0,.75):0;
  result.autoFitSaturation=1;
  result.autoFitKey=result.autoFitMode==='natural'&&typeof input?.autoFitKey==='string'&&input.autoFitKey.length<=800?input.autoFitKey:'';
  for (const key of ['spectralFilm','spectralPaper']) result[key] = typeof input?.[key] === 'string' && /^[a-z0-9_-]{1,100}$/.test(input[key]) ? input[key] : DEFAULTS[key];
  result.filmFormat = input?.filmFormat === 60 ? 60 : 35;
  result.spectralEdge = input?.spectralEdge === true;
  result.spectralDate = input?.spectralDate === true;
  const dateText=typeof input?.spectralDateText==='string'?input.spectralDateText.trim():'';
  const date=/^(19|20)\d{2}-\d{2}-\d{2}$/.test(dateText)?new Date(dateText+'T00:00:00Z'):null;
  result.spectralDateText=date&&Number.isFinite(date.getTime())&&date.toISOString().slice(0,10)===dateText?dateText:'';
  result.spectralMask = input?.spectralMask === true;
  for (const key of ['spectralMaskHighlights','spectralMaskShadows']) { const v=input?.[key]; result[key]=typeof v==='number'&&Number.isFinite(v)?clamp(v,0,3):0; }
  result.printExposure = typeof input?.printExposure === 'number' && Number.isFinite(input.printExposure) ? clamp(input.printExposure,-3,3) : 0;
  for (const key of ['strength','exposure','highlights','shadows','contrast','temperature','saturation','grain','halation','bloom']) {
    const v = input?.[key];
    const exposureLimit = result.engine === 'spectral' && result.spectralVersion === 2 ? 8 : 2;
    result[key] = typeof v === 'number' && Number.isFinite(v) ? clamp(v, key === 'strength' ? 0 : key === 'exposure' ? -exposureLimit : 0 <= ['grain','halation','bloom'].indexOf(key) ? 0 : -100, key === 'exposure' ? exposureLimit : 100) : DEFAULTS[key];
  }
  return result;
}
function hasEdits(a) { return a.engine === 'spectral' || (a.lut && a.strength > 0) || ['exposure','highlights','shadows','contrast','temperature','saturation','grain','halation','bloom'].some(k => a[k] !== 0); }
function parseCube(text) {
  const textBytes = typeof TextEncoder !== 'undefined' ? new TextEncoder().encode(text).byteLength : Buffer.byteLength(text, 'utf8');
  if (textBytes > 32e6) throw Error('LUT 文件超过 32 MB');
  let size = 0, title = '', min = [0,0,0], max = [1,1,1]; const rows = [];
  for (const raw of text.replace(/^\uFEFF/,'').split(/\r?\n/)) {
    const line = raw.split('#')[0].trim(); if (!line) continue;
    if (/^TITLE\s/i.test(line)) { title = line.replace(/^TITLE\s+/i,'').replace(/^"|"$/g,'').slice(0,120); continue; }
    const parts = line.split(/\s+/), tag = parts[0];
    if (tag === 'LUT_1D_SIZE') throw Error('需要三维 LUT，不支持一维 .cube');
    if (tag === 'LUT_3D_SIZE') { size = Number(parts[1]); if (!Number.isInteger(size) || size < 2 || size > 65) throw Error('LUT 网格必须为 2–65'); continue; }
    if (tag === 'DOMAIN_MIN' || tag === 'DOMAIN_MAX') { const v = parts.slice(1).map(Number); if(v.length!==3||v.some(x=>!Number.isFinite(x)))throw Error('无效 LUT 输入域'); if(tag==='DOMAIN_MIN')min=v;else max=v; continue; }
    const v = parts.map(Number); if(v.length!==3||v.some(x=>!Number.isFinite(x)||Math.abs(x)>16))throw Error('LUT 包含无效节点');
    rows.push(...v); if(rows.length>65**3*3)throw Error('LUT 节点过多');
  }
  if(!size||rows.length!==size**3*3)throw Error('LUT 节点数与网格尺寸不一致');
  if(min.some((v,k)=>max[k]<=v))throw Error('LUT 输入域范围无效');
  return { size, title, min, max, data: new Float32Array(rows) };
}
function sampleCube(cube, r, g, b, out) {
  const n=cube.size,m=n-1;
  const x=clamp((r-cube.min[0])/(cube.max[0]-cube.min[0]),0,1)*m,y=clamp((g-cube.min[1])/(cube.max[1]-cube.min[1]),0,1)*m,z=clamp((b-cube.min[2])/(cube.max[2]-cube.min[2]),0,1)*m;
  const x0=Math.floor(x),y0=Math.floor(y),z0=Math.floor(z),x1=Math.min(m,x0+1),y1=Math.min(m,y0+1),z1=Math.min(m,z0+1),tx=x-x0,ty=y-y0,tz=z-z0,d=cube.data;
  const a=(z0*n*n+y0*n+x0)*3,b0=(z0*n*n+y0*n+x1)*3,c=(z0*n*n+y1*n+x0)*3,e=(z0*n*n+y1*n+x1)*3,f=(z1*n*n+y0*n+x0)*3,h=(z1*n*n+y0*n+x1)*3,i=(z1*n*n+y1*n+x0)*3,j=(z1*n*n+y1*n+x1)*3;
  for(let k=0;k<3;k++){const lo=(d[a+k]*(1-tx)+d[b0+k]*tx)*(1-ty)+(d[c+k]*(1-tx)+d[e+k]*tx)*ty;const hi=(d[f+k]*(1-tx)+d[h+k]*tx)*(1-ty)+(d[i+k]*(1-tx)+d[j+k]*tx)*ty;out[k]=lo*(1-tz)+hi*tz;}
  return out;
}
const toLinear = new Float64Array(256).map((_,v)=>{const c=v/255;return c<=.04045?c/12.92:((c+.055)/1.055)**2.4;});
const encode = v => v <= .0031308 ? 12.92*v : 1.055*Math.pow(Math.max(0,v),1/2.4)-.055;
const smooth = (lo,hi,v) => { const x=clamp((v-lo)/(hi-lo),0,1); return x*x*(3-2*x); };
function applyPixels(data, channels, adjustments, cube=null) {
  const a=cleanAdjustments(adjustments);if(!hasEdits(a))return data;
  const gain=2**a.exposure,redGain=Math.exp(a.temperature*.0017),blueGain=1/redGain,contrast=2**(a.contrast*.008),sat=1+a.saturation/100,strength=a.lut&&cube?a.strength/100:0,out=[0,0,0];
  for(let p=0;p<data.length;p+=channels){
    let r=toLinear[data[p]]*gain*redGain,g=toLinear[data[p+1]]*gain,b=toLinear[data[p+2]]*gain*blueGain;
    const y=.2126*r+.7152*g+.0722*b;
    const tone=(1+a.shadows*.008*(1-smooth(.015,.35,y)))*(1+a.highlights*.007*smooth(.15,1,y));
    r=clamp((encode(r*tone)-.5)*contrast+.5,0,1);g=clamp((encode(g*tone)-.5)*contrast+.5,0,1);b=clamp((encode(b*tone)-.5)*contrast+.5,0,1);
    if(strength){sampleCube(cube,r,g,b,out);r+=(out[0]-r)*strength;g+=(out[1]-g)*strength;b+=(out[2]-b)*strength;}
    const l=.2126*r+.7152*g+.0722*b;
    r=clamp(l+(r-l)*sat,0,1);g=clamp(l+(g-l)*sat,0,1);b=clamp(l+(b-l)*sat,0,1);
    if(strength&&a.autoFitMode==='natural'&&(a.autoFitEV!==0||a.autoFitSaturation!==1)){
      const decode=v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4;
      const fitted=autoFitMath.correctLinear(decode(r),decode(g),decode(b),a.autoFitEV,a.autoFitSaturation);
      r=encode(fitted[0]);g=encode(fitted[1]);b=encode(fitted[2]);
    }
    data[p]=Math.round(clamp(r,0,1)*255);data[p+1]=Math.round(clamp(g,0,1)*255);data[p+2]=Math.round(clamp(b,0,1)*255);
  }
  return data;
}
// Spatial film texture pass. Noise is coordinate-seeded (not time-seeded), so previews/export remain stable.
function applyTexture(data, width, height, channels, adjustments) {
  const a=cleanAdjustments(adjustments), grain=a.grain/100, halo=a.halation/100, bloom=a.bloom/100;
  if (!grain && !halo && !bloom) return data;
  const n=width*height, lum=new Float32Array(n); for(let i=0,p=0;i<n;i++,p+=channels) lum[i]=(.2126*data[p]+.7152*data[p+1]+.0722*data[p+2])/255;
  const source=typeof Buffer !== 'undefined' ? Buffer.from(data) : Uint8Array.from(data);
  // Integral images make both spatial passes O(N), even for large exports.
  const stride=width+1, integral=(halo||bloom)?new Float64Array((height+1)*stride):null;
  if(halo||bloom) for(let y=1;y<=height;y++){let row=0;for(let x=1;x<=width;x++){const v=Math.max(0,(lum[(y-1)*width+x-1]-.62)/.38);row+=v;integral[y*stride+x]=integral[(y-1)*stride+x]+row;}}
  const box=(x,y,r)=>{const x0=Math.max(0,x-r),y0=Math.max(0,y-r),x1=Math.min(width-1,x+r),y1=Math.min(height-1,y+r);const area=(x1-x0+1)*(y1-y0+1);return (integral[(y1+1)*stride+x1+1]-integral[y0*stride+x1+1]-integral[(y1+1)*stride+x0]+integral[y0*stride+x0])/area;};
  const haloRadius=Math.max(1,Math.min(18,Math.round(Math.min(width,height)/180))), bloomRadius=Math.max(2,Math.min(36,haloRadius*2));
  for(let y=0,p=0;y<height;y++)for(let x=0;x<width;x++,p+=channels){const i=y*width+x, l=lum[i];
    if(grain){
      // Bilinear interpolation on a ~1800px reference grid avoids large preview blocks.
      const gx=x*1800/Math.max(1,width), gy=y*1800/Math.max(1,height), ix=Math.floor(gx), iy=Math.floor(gy), tx=gx-ix, ty=gy-iy;
      const hash=(xx,yy)=>{let h=Math.imul(xx+1,374761393)^Math.imul(yy+1,668265263);h=Math.imul(h^(h>>>13),1274126177);return ((h^(h>>>16))>>>0)/4294967295-.5;};
      const smooth=(hash(ix,iy)*(1-tx)+hash(ix+1,iy)*tx)*(1-ty)+(hash(ix,iy+1)*(1-tx)+hash(ix+1,iy+1)*tx)*ty;
      let ph=Math.imul(x+1,1597334677)^Math.imul(y+1,3812015801);ph=Math.imul(ph^(ph>>>13),1274126177);const fine=((ph^(ph>>>16))>>>0)/4294967295-.5;
      const noise=smooth*.82+fine*.18, amount=noise*grain*.22*(.2+.8*l);for(let k=0;k<3;k++)data[p+k]=Math.round(Math.max(0,Math.min(255,source[p+k]+amount*255)));
    }
    if(halo||bloom){const bright=Math.max(0,(l-.62)/.38);if(halo){const edge=Math.max(0,box(x,y,haloRadius)-bright)*halo*.55;data[p]=Math.min(255,data[p]+edge*255);data[p+1]=Math.min(255,data[p+1]+edge*62);}if(bloom){const glow=box(x,y,bloomRadius)*bloom*.24;for(let k=0;k<3;k++)data[p+k]=Math.min(255,data[p+k]+glow*255);}}
  } return data;
}
const LightTableFilm = { DEFAULTS, SPECTRAL_DEFAULTS, NATURAL_SPECTRAL_DEFAULTS, spectralDefaults, naturalDefaults, withSpectralIntent, withSpectralFilm, withLut, cleanAdjustments, hasEdits, parseCube, sampleCube, applyPixels, applyTexture };
if (typeof module !== 'undefined' && module.exports) module.exports = LightTableFilm;
if (typeof self !== 'undefined') self.LightTableFilm = LightTableFilm;
