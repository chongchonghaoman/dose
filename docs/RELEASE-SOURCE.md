# dose 0.29.0 corresponding source

`LightTable-Windows` is the dose application source, including the new Electron/platform bridge, tests and lockfile. `SpektraLab-community/desktop` is the original editor with the minimal Electron adapter and return toolbar. `SpektraLab-port` is the legacy dose engine source; the new reference editor uses the **unmodified** release host supplied in `upstream-release-source`.

The native executable is byte-identical to LUOJW5566/SpektraLab v1.3.1-windows.1. Its full matching source, original dependency source archives, licences, build records and reproduction instructions are retained in `upstream-release-source`. Read its `README-SOURCE.txt` and `reproduce-editor.ps1` to rebuild that native/Tauri release. It also retains the upstream's licence provenance notes. dose does not modify that executable. For the legacy engine, see `SpektraLab-port` and its CMake/Windows build instructions; the LibRaw and Vulkan header source copies are included under `spectral-tools`.

To rebuild this Electron integration on Windows with Node/npm installed, run in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\rebuild-dose-reference.ps1 -PackagedApp C:\path\to\dose-0.29.0
```

`-PackagedApp` is the directory containing the supplied dose.exe and resources. This command reuses its exact native binaries/resources, installs pinned npm dependencies, typechecks/builds the frontend, and packages the rebuilt dose in `build-output`. Replace the native resource directories with your own rebuilt binaries if rebuilding the engines too. Build tools and Node/npm are not included; this is not an offline toolchain bundle.

The original processing, color, crop and export functions are unchanged. Integration-specific code lives in dose's `src/reference-*.cjs` plus community frontend `src/platform/electron.ts`, `src/host/electronTransport.ts` and `src/doseIntegration.tsx`. The dose toolbar and minimal launch/return hooks are in `main.cjs`, `preload.cjs`, `renderer.js` and `index.html`. Returned TIFF files are derivatives, with original source references and sidecars retained.

This revision adds photo-only magazine pages, a persistent main-photo choice, ordered opening/group/closing layouts and individual JPEG/PNG page exports with sRGB profiles. The application source under LightTable-Windows is the current public repository snapshot. SpektraLab-community/desktop mirrors its vendor/spektralab/desktop directory; the native sources and dependencies are retained from the complete 0.28 source archive. RELEASE-PROVENANCE.json in the archive records the exact application commit and base archive hash.

Validation for 0.29.0: 70 unit tests, 3 preferences tests, source and packaged magazine workflow checks, main-photo undo/redo and persistence, per-page JPEG/PNG exports, and actual desktop screenshots. A separate packaged run with the Japan demonstration photos also exercised LUT thumbnails and a native TIFF return. The native frontend and engine are unchanged; native engine rebuilding, DNG and pair checks were not repeated for this revision.

Run npm test and npm run test:preferences in LightTable-Windows. Current UI suites include npm run test:magazine-desktop, npm run test:photo-workflow, node tests/lut-panel-desktop.cjs and node tests/reference-editor.cjs (set DOSE_REFERENCE_EXTENDED=1 for repeated editing and close-save). Historical desktop suites address older controls and are retained as development history, not all current UI acceptance gates. Test input photos are excluded; npm run test:fixtures downloads the six public JPEG fixtures. Reference integration can also take DOSE_REFERENCE_INPUT. Tests use isolated profiles and close their own app instances. Published screenshots retain their separate photo licenses, documented in docs/PHOTO-CREDITS.md.

GPL-3.0-or-later. Original author/community attribution and bundled third-party notices are retained. Repository: https://github.com/LUOJW5566/SpektraLab
