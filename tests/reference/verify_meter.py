"""NumPy interpretation of RFC-015's four meters + independent CPU render."""
import json
import numpy as np,colour
from verify_core import Engine,DLL,RES,OUT,BASE,input_frames,cpu_render,counts
def meters(frame):
    y=np.einsum('...c,c->...',frame.astype(np.float64),colour.RGB_COLOURSPACES['ProPhoto RGB'].matrix_RGB_to_XYZ[1]);y=np.maximum(y,.184/4096)
    ordered=np.sort(y.ravel());rank=lambda q:ordered[q*(y.size-1)//1000]
    p1,p5,p99,p995=map(rank,(10,50,990,995));trim=(y>=p1)&(y<=p99)
    balanced=-np.log2(np.exp(np.log(y[trim]).mean())/.184)
    h,w=y.shape;long=max(h,w);xs=(np.arange(w)/w-.5)*w/long;ys=(np.arange(h)/h-.5)*h/long;weights=np.exp(-(ys[:,None]**2+xs[None,:]**2)/(2*.2**2))*trim
    center=-np.log2(np.exp((np.log(y)*weights).sum()/weights.sum())/.184)
    return dict(balanced=balanced,center=center,protect_highlights=np.clip(np.log2(.184*2**2.5/p995),balanced-3,balanced),protect_shadows=np.clip(np.log2(.184*2**-3.5/p5),balanced,balanced+2))
records=[]
with Engine(library=DLL,resources=RES) as eng:
    for name,decode,frame in input_frames():
        for method,ev in meters(frame).items():
            delta={**BASE,'film_stock':'kodak_portra_400','print_stock':'kodak_supra_endura','product_defaults':True}
            with eng.open(frame,{**delta,'auto_exposure':True,'auto_exposure_method':method}) as session:got,_=session.render('full')
            want=counts(cpu_render(np.ascontiguousarray((frame*float(2**ev)).astype(np.float32)),delta));diff=np.abs(got[...,:3].astype(np.int32)-want.astype(np.int32))
            rec=dict(input=name,method=method,ev=float(ev),max16=int(diff.max()),mean16=float(diff.mean()),over1Fraction=float((diff>1).mean()));records.append(rec);print(json.dumps(rec),flush=True)
            assert diff.max()<=1,rec
(OUT/'independent-meter-report.json').write_text(json.dumps(dict(reference='RFC-015 meter evaluated independently with NumPy, then public CPU film model',cases=records),indent=2))

