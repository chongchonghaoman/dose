# dose 0.28.0 corresponding source

`LightTable-Windows` is the dose application source, including the new Electron/platform bridge, tests and lockfile. `SpektraLab-community/desktop` is the original editor with the minimal Electron adapter and return toolbar. `SpektraLab-port` is the legacy dose engine source; the new reference editor uses the **unmodified** release host supplied in `upstream-release-source`.

The native executable is byte-identical to LUOJW5566/SpektraLab v1.3.1-windows.1. Its full matching source, original dependency source archives, licences, build records and reproduction instructions are retained in `upstream-release-source`. Read its `README-SOURCE.txt` and `reproduce-editor.ps1` to rebuild that native/Tauri release. It also retains the upstream's licence provenance notes. dose does not modify that executable. For the legacy engine, see `SpektraLab-port` and its CMake/Windows build instructions; the LibRaw and Vulkan header source copies are included under `spectral-tools`.

To rebuild this Electron integration on Windows with Node/npm installed, run in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\rebuild-dose-reference.ps1 -PackagedApp C:\path\to\dose-0.28.0
```

`-PackagedApp` is the directory containing the supplied dose.exe and resources. This command reuses its exact native binaries/resources, installs pinned npm dependencies, typechecks/builds the frontend, and packages the rebuilt dose in `build-output`. Replace the native resource directories with your own rebuilt binaries if rebuilding the engines too. Build tools and Node/npm are not included; this is not an offline toolchain bundle.

The original processing, color, crop and export functions are unchanged. Integration-specific code lives in dose's `src/reference-*.cjs` plus community frontend `src/platform/electron.ts`, `src/host/electronTransport.ts` and `src/doseIntegration.tsx`. The dose toolbar and minimal launch/return hooks are in `main.cjs`, `preload.cjs`, `renderer.js` and `index.html`. Returned TIFF files are derivatives, with original source references and sidecars retained.

This revision adds a separate single-photo view, current-photo LUT thumbnail browsing and favorites, library search/placement filters and sorting. Its state does not change the table's photo placement or camera. Favorite LUTs and sort preference use userData/ui-preferences.json. The LUT-only inspector, sRGB exports and complete reference editor remain intact.

Validation for 0.28.0: dose unit tests (58), preferences persistence tests (3), source and packaged single-photo/LUT/library workflow checks, LUT desktop integration/export checks, packaged native-edge/Post-Dev/16-bit TIFF roundtrip/reopen/close-save checks, and actual 1440x960 and 980x680 screenshots. See the verification receipts. The reference editor frontend and binaries are unchanged from 0.27.0; its earlier typecheck/build remains valid. DNG and pair checks were not rerun in this UI revision.

Run npm test and npm run test:preferences in LightTable-Windows. Current UI suites: npm run test:photo-workflow, node tests/lut-panel-desktop.cjs and node tests/reference-editor.cjs (set DOSE_REFERENCE_EXTENDED=1 for repeated editing and close-save). Historical desktop suites address older controls and are retained as development history, not all current UI acceptance gates. Test photos are excluded. Supply JPEG fixtures named 01-valley.jpg, 02-river.jpg, 03-cliff.jpg, 04-waterfall.jpg, 05-landscape.jpg and 06-castle.jpg under tests/fixtures. The two-image LUT suite only needs the first two. Reference integration can also take DOSE_REFERENCE_INPUT. Tests use isolated profiles and close their own app instances.

GPL-3.0-or-later. Original author/community attribution and bundled third-party notices are retained. Repository: https://github.com/LUOJW5566/SpektraLab
