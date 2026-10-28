# Independent colour reference checks

Development checks only. Python is not an application runtime requirement.

The source root contains sibling `LightTable-Windows`, `SpektraLab-port`, and `spectral-tools` directories. Clone `https://github.com/andreavolpato/spektrafilm` into a sibling `spektrafilm-research` directory and check out commit `3bb2c2d2801ff68b92019cf1dbcbb133d60832bc` (0.3.4). Preserve that repository's GPL and data licences. Do not install its GUI for these checks.

Use a separate Python 3.13 environment and install `requirements-tested.txt`, the exact package versions measured in this workspace. The source checkout is imported directly, so an editable package install is unnecessary. Build the native host as described in `SPECTRAL-BUILD.md`; BUILD_TESTING also builds the C ABI DLL at `SpektraLab-port/build/dose-windows/engine/spektrafilm_engine.dll`. The checks import ctypes declarations from the original engine tests.

Provide these fixtures in `LightTable-Windows/tests/`:

- `fixtures/01-valley.jpg`: Picsum image 1018, as used by the ordinary desktop fixture generator.
- `dng-fixtures/Apple-iPhone-12-Pro.DNG` and `Ricoh-GR-III.DNG`: CC0 files from `https://github.com/tellodaniel/revelraw-sample-raw-files/releases/tag/v1`. They are not included in the source archive.

Run with the environment's Python executable:

```text
python LightTable-Windows/tests/reference/verify_core.py
python LightTable-Windows/tests/reference/verify_meter.py
```

`verify_core` supplies the same float32 linear ProPhoto image to the Vulkan C ABI and the separately executed public CPU model. JPEG is decoded from sRGB using CAT02; RAW uses rawpy ProPhoto/linear, camera white balance, AHD and no auto bright. It preserves aspect ratio at a 256px long edge, pairs each film with its declared paper and enables direct scan for positive stocks. All twenty colour films, three image sources and five parameter variants are checked (300 cases). Grain/glare are disabled for deterministic comparison; halation is at its original amount of 1. A failed decode or numerical check fails the run. No fallback input is substituted.

`verify_meter` independently evaluates the four RFC-015 meter equations with NumPy, then compares the resulting public CPU-model picture with a native automatic-meter render (12 cases). These are image-prefix tests at the sample's resolution, not a claim that rawpy reproduces Apple's CIRAWFilter.

For export conversion, first run `node tests/colour-output.cjs` from `LightTable-Windows`; then run `python LightTable-Windows/tests/reference/verify_output.py`. It consumes the generated ProPhoto and sRGB RGBA16 samples under `outputs/v0.12.0/verification` next to the source root's parent and evaluates the original export contract independently using colour-science/CAM16, with repeated lightness compression disabled. Both preview samples and output quantisation are included in the reported bounds.

The numerical gate follows upstream `parity_render.py`: float absolute error at most 3e-5 and fraction exceeding one uint16 count at most 1e-5. These tests verify the deterministic physical model, meter and export math. They do not execute the macOS binary or prove ColorSync/Chromium equivalence. The browser CMS check is separately measured in `colour-desktop-report.json`.
