"""The Mac export contract, evaluated by colour-science/NumPy, not the host."""
import sys,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'spektrafilm-research/src'))
import numpy as np,colour
from spektrafilm.utils.gamut_compression import compress_rgb,OutputGamutCompressSpec
OUT=ROOT.parent/'outputs/v0.12.0/verification'
cases=json.loads((OUT/'colour-output-report.json').read_text())['cases'];results=[]
for i,case in enumerate(cases,1):
    shape=(case['height'],case['width'],4)
    encoded=np.fromfile(OUT/f'colour-{i}-engine.rgba16',dtype='<u2').reshape(shape)[...,:3]/65535
    actual=np.fromfile(OUT/f'colour-{i}-srgb.rgba16',dtype='<u2').reshape(shape)[...,:3]
    target=colour.RGB_to_RGB(encoded,'ProPhoto RGB','sRGB',apply_cctf_decoding=True,apply_cctf_encoding=False,chromatic_adaptation_transform='CAT02')
    wanted=compress_rgb(target,OutputGamutCompressSpec(lightness_compression=None),output_color_space='sRGB')
    # Canvas/Shaders.metal outputTransform applies the target transfer curve
    # directly. RGB_to_RGB(sRGB,sRGB) would multiply an extra, nonidentity
    # rounded matrix that this export shader does not contain.
    wanted=colour.cctf_encoding(wanted,function='sRGB')
    counts=np.floor(np.clip(wanted,0,1)*65535+.5).astype(np.int32)
    delta=np.abs(actual.astype(np.int32)-counts)
    r={'input':case['input'],'max16':int(delta.max()),'mean16':float(delta.mean()),'over1Fraction':float((delta>1).mean())};results.append(r);print(json.dumps(r),flush=True)
    # The independent reference calculates float64; the shader/host contract
    # is float32. 3e-5 absolute includes final uint16 quantisation as upstream
    # parity_render documents. Never accept a systematic code-value shift.
    float_error=np.abs(actual/65535-np.clip(wanted,0,1))
    assert float_error.max()<=3e-5 and (delta>1).mean()<=1e-5,r
(OUT/'independent-output-report.json').write_text(json.dumps({'reference':'Public spektrafilm CAM16 / colour-science CPU; Mac ColourManagement.swift disables repeated lightness shoulder','cases':results},indent=2))

