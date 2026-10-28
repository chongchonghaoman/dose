#!/usr/bin/env python3
"""Bake the shared virtual 5294 / LED-B5 fit into a linear sRGB CI cube."""
from pathlib import Path
import hashlib
import json
import sys

import colour
import numpy as np
from scipy.interpolate import RegularGridInterpolator

ROOT = Path(__file__).resolve().parents[1]
STUDY = ROOT.parent / "docs/research/film-transmission-v1.2"
DATA = STUDY / "data"
PREPARE = STUDY / "prepare.py"
OUTPUT = ROOT / "Sources/LightTableApp/Resources/FilmTransmission.cube"
REPORT = ROOT / "Sources/LightTableApp/Resources/FilmTransmission.json"
DIMENSION = 32
AXIS = np.linspace(0, 1, 25)


def main():
    import importlib.util

    spec = importlib.util.spec_from_file_location("spectral_prepare", PREPARE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    spectral = np.load(DATA / "spectral-inputs.npz")
    dyes = spectral["dyes"]
    observer_led = spectral["observer_led"]
    observer_d65 = spectral["observer_d65"]
    fitted = np.load(DATA / "dye-cube.npy").astype(np.float64)
    fit = RegularGridInterpolator((AXIS, AXIS, AXIS), fitted, bounds_error=False, fill_value=None)

    coordinates = np.linspace(0, 1, DIMENSION)
    blue, green, red = np.meshgrid(coordinates, coordinates, coordinates, indexing="ij")
    linear_srgb = np.stack((red, green, blue), axis=-1).reshape(-1, 3)
    encoded_srgb = colour.models.eotf_inverse_sRGB(linear_srgb)
    amounts = np.maximum(fit(encoded_srgb), 0)
    led_transmission = module.integrate_amounts(amounts, dyes, observer_led)
    led_transmission = np.clip(led_transmission, 1e-5, 1) * 10 ** (-module.BASE_DENSITY)

    rgba = np.ones((DIMENSION, DIMENSION, DIMENSION, 4), dtype="<f4")
    # CIColorCube expects red to vary fastest, then green, then blue.
    rgba[..., :3] = led_transmission.reshape(DIMENSION, DIMENSION, DIMENSION, 3)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = rgba.tobytes(order="C")
    OUTPUT.write_bytes(payload)
    report = {
        "version": 1,
        "cubeDimension": DIMENSION,
        "cubeColorSpace": "extendedLinearSRGB",
        "spectralSource": str(STUDY / "manifest.json"),
        "spectralSourceSHA256": hashlib.sha256((STUDY / "manifest.json").read_bytes()).hexdigest(),
        "dyeCurveSource": str(module.CURVES),
        "dyeCurveSourceSHA256": module.digest(module.CURVES),
        "fitSourceSHA256": hashlib.sha256((DATA / "dye-cube.npy").read_bytes()).hexdigest(),
        "lamp": "CIE LED-B5",
        "input": "ICC-normalized sRGB linear -> sRGB encoded -> shared D65 3-dye fit",
        "output": "LED-B5 spectral transmission including base density -> extended linear sRGB; no per-pixel luminance normalization",
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "scope": "Same hypothetical virtual 5294 dye basis for all source images; models lamp-dependent material transmission, not actual film-stock identification",
    }
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
