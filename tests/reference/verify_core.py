"""Independent CPU/native colour parity audit.

The CPU side is the public spektrafilm runtime; native is loaded through the
shipping C ABI. Inputs are converted once to float32 linear ProPhoto and that
same array is passed to both sides.  This deliberately does not use a native
render as the CPU expectation.
"""
from __future__ import annotations
import json, sys, time
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "SpektraLab-port/engine/tests"))
sys.path.insert(0, str(ROOT / "spektrafilm-research/src"))
from spk_ctypes import Engine
from spektrafilm.runtime.params_builder import init_params, digest_params
from spektrafilm.runtime.pipeline import SimulationPipeline

DLL = ROOT / "SpektraLab-port/build/dose-windows/engine/spektrafilm_engine.dll"
RES = ROOT / "LightTable-Windows/native/spectral/engine"
OUT = ROOT.parent / "outputs/colour-pipeline-audit/core-reference"
OUT.mkdir(parents=True, exist_ok=True)
BASE = {"auto_exposure": False, "grain_active": False, "glare_active": False,
        "halation_active": True, "halation_amount": 1.0,
        "film_format_mm": 36.0, "input_color_space": "ProPhoto RGB",
        "input_cctf_decoding": False, "output_color_space": "ProPhoto RGB",
        "output_cctf_encoding": True}

# All colour stocks present in the native profile directory; monochrome stocks
# are excluded.  The list is intentionally explicit and recorded in the JSON.
STOCKS = [
 "kodak_portra_160", "kodak_portra_400", "kodak_portra_800",
 "kodak_portra_800_push1", "kodak_portra_800_push2", "kodak_gold_200",
 "kodak_ektar_100", "kodak_ultramax_400", "kodak_verita_200d",
 "kodak_ektachrome_100", "kodak_kodachrome_64", "kodak_vision3_50d",
 "kodak_vision3_200t", "kodak_vision3_250d", "kodak_vision3_500t",
 "fujifilm_c200", "fujifilm_pro_400h", "fujifilm_provia_100f",
 "fujifilm_velvia_100", "fujifilm_xtra_400",
]
POSITIVE = {"kodak_ektachrome_100", "kodak_kodachrome_64",
            "fujifilm_provia_100f", "fujifilm_velvia_100"}

def input_frames():
    """Return three real fixture samples, normalized to linear ProPhoto float32.

    JPEGs are decoded with Pillow and colour-science from sRGB to linear
    ProPhoto. DNGs use rawpy linear ProPhoto16 with camera white balance.
    A failed decode is a failure; no substitute image is accepted.
    """
    paths = [ROOT / "LightTable-Windows/tests/fixtures/01-valley.jpg",
             ROOT / "LightTable-Windows/tests/dng-fixtures/Apple-iPhone-12-Pro.DNG",
             ROOT / "LightTable-Windows/tests/dng-fixtures/Ricoh-GR-III.DNG"]
    frames = []
    for path in paths:
        note = "pillow"; arr = None
        try:
            if path.suffix.lower() == ".dng":
                import rawpy
                with rawpy.imread(str(path)) as r:
                    arr = r.postprocess(output_color=rawpy.ColorSpace.ProPhoto,
                        gamma=(1, 1), output_bps=16, no_auto_bright=True,
                        use_camera_wb=True, demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD)
                note = "rawpy-linear-ProPhoto"
            else:
                from PIL import Image
                arr = np.asarray(Image.open(path).convert("RGB"))
        except Exception as exc:
            if path.suffix.lower() == ".dng":
                raise RuntimeError(f"DNG decode failed for {path.name}: {exc}") from exc
            note = "sRGB-JPEG"
        arr = np.asarray(arr, dtype=np.float32)
        if path.suffix.lower() != ".dng":
            import colour
            arr = colour.RGB_to_RGB(arr / 255.0, "sRGB", "ProPhoto RGB", "CAT02",
                                    apply_cctf_decoding=True, apply_cctf_encoding=False)
        else:
            arr /= 65535.0
        # Bilinear sample reduction preserving aspect ratio, long edge 256.
        from PIL import Image
        h, w = arr.shape[:2]; scale = 256.0 / max(h, w)
        size = (max(1, round(w * scale)), max(1, round(h * scale)))
        if size != (w, h):
            from scipy.ndimage import zoom
            arr = zoom(arr, (size[1] / h, size[0] / w, 1), order=1).astype(np.float32)
        arr = np.ascontiguousarray(arr.astype(np.float32))
        frames.append((path.name, note, np.ascontiguousarray(arr.astype(np.float32))))
    return frames

def cpu_render(frame, delta, resolved_space="ProPhoto RGB"):
    p = init_params(delta.get("film_stock", "kodak_portra_400"),
                    delta.get("print_stock", "kodak_portra_endura"))
    # Explicit schema path mapping; this avoids service.schema dependency.
    fields = {"exposure_compensation_ev":"camera.exposure_compensation_ev", "auto_exposure":"camera.auto_exposure",
      "film_format_mm":"camera.film_format_mm", "halation_active":"film_render.halation.active", "halation_amount":"film_render.halation.halation_amount",
      "grain_active":"film_render.grain.active", "dir_couplers_active":"film_render.dir_couplers.active", "dir_couplers_amount":"film_render.dir_couplers.amount",
      "density_curve_gamma":"film_render.density_curve_gamma", "input_color_space":"io.input_color_space", "input_cctf_decoding":"io.input_cctf_decoding", "print_exposure":"enlarger.print_exposure", "m_filter_shift":"enlarger.m_filter_shift", "y_filter_shift":"enlarger.y_filter_shift", "preflash_exposure":"enlarger.preflash_exposure",
      "glare_active":"print_render.glare.active", "output_color_space":"io.output_color_space", "output_cctf_encoding":"io.output_cctf_encoding", "scan_film":"io.scan_film"}
    for key, value in delta.items():
        if key in ("film_stock", "print_stock", "product_defaults"): continue
        path = fields.get(key)
        if not path: raise RuntimeError(f"unmapped field {key}")
        dst = p
        parts = path.split(".")
        for part in parts[:-1]: dst = getattr(dst, part)
        setattr(dst, parts[-1], value)
    if delta.get("product_defaults"): p.enlarger.print_exposure_compensation = False
    p = digest_params(p)
    return np.asarray(SimulationPipeline(p).process(frame), dtype=np.float32)

def counts(a): return (np.clip(np.asarray(a, dtype=np.float32), 0, 1) * 65535 + .5).astype(np.uint16)

def main():
    frames = input_frames(); records=[]; t0=time.time()
    profile_targets = {}
    for stock in STOCKS:
        info = json.loads((RES / "profiles" / f"{stock}.json").read_text(encoding="utf-8"))["info"]
        target = info.get("target_print")
        profile_targets[stock] = target if isinstance(target, str) and target else "kodak_portra_endura"
    for i, (_, _, frame) in enumerate(frames): np.save(OUT / f"input-linear-prophoto-{i}.npy", frame)
    with Engine(library=DLL, resources=RES) as eng:
        schema = eng.params_schema(); profileinfo = [x for x in schema.get("fields", []) if x.get("name") in ("film_stock", "print_stock")]
        for stock in STOCKS:
            for fi, (fname, decode, frame) in enumerate(frames):
                scan = stock in POSITIVE
                for variant, extra in [("base", {}), ("exposure_up", {"exposure_compensation_ev": 1.0}), ("exposure_down", {"exposure_compensation_ev": -1.0}), ("filters", {"m_filter_shift": .35, "y_filter_shift": -.25, "print_exposure": 1.2}), ("product_supra", {"product_defaults": True, "print_stock": "kodak_supra_endura", "print_exposure": 1.15})]:
                    d = {**BASE, "film_stock": stock, "print_stock": profile_targets[stock], "scan_film": scan, **extra}
                    started=time.time()
                    try:
                        with eng.open(frame, d) as s: native,_=s.render("full")
                        want=counts(cpu_render(frame,d))
                        got=native[..., :3].astype(np.uint16); delta=np.abs(got.astype(np.int32)-want.astype(np.int32))
                        float_delta=np.abs(got.astype(np.float32)/65535.0 - np.clip(cpu_render(frame,d),0,1))
                        over=float((delta>1).mean()); valid=bool(float_delta.max() <= 3e-5 and over <= 1e-5)
                        rec={"stock":stock,"target_print":d["print_stock"],"input":fname,"decode":decode,"variant":variant,"scan_film":scan,"width":int(frame.shape[1]),"height":int(frame.shape[0]),"range":[float(frame.min()),float(frame.max())],"input_type":"float32 linear ProPhoto RGB","max16":int(delta.max()),"maxFloat":float(float_delta.max()),"mean16":float(delta.mean()),"over1Fraction":over,"ms":round((time.time()-started)*1000),"status":"ok" if valid else "fail"}
                        if stock == STOCKS[0] and fi == 0: np.save(OUT / f"native-{variant}.npy", native); np.save(OUT / f"cpu-{variant}.npy", want)
                    except Exception as exc:
                        rec={"stock":stock,"input":fname,"variant":variant,"status":"error","error":repr(exc)}
                    records.append(rec); print(json.dumps(rec), flush=True)
    report={"generated":"independent CPU vs native C ABI","stocks":STOCKS,"stockCount":len(STOCKS),"inputs":[x[0] for x in frames],"records":records,"threshold":{"floatAbs":3e-5,"count":1,"outlierFraction":1e-5},"elapsed_s":round(time.time()-t0,2)}
    target = OUT / "core-reference-errors-corrected.json"
    report["failedCount"] = sum(x.get("status") != "ok" for x in records)
    target.write_text(json.dumps(report,indent=2), encoding="utf-8")
    print(json.dumps({"output":str(target),"records":len(records),"failedCount":report["failedCount"]}))
    if report["failedCount"]: raise SystemExit(2)
if __name__ == "__main__": main()

