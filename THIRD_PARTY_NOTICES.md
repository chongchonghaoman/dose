# Third-party notices

## LightTable upstream

Project: https://github.com/fuyuan9972-svg/LightTable

Reference commit: 1a998cfce9096ac7b42e26aba67c922885fd43e2.

Original MIT copyright and permission notice is preserved in licenses/LightTable-MIT.txt and in the native runtime. The dose brand replaces the original icon. This is an independent photo-workflow project, not an official upstream release. The integrated dose distribution is GPL-3.0-or-later; see LICENSE. The GitHub fork preserves LightTable ancestry; its historical macOS tree is not part of the dose Windows runtime.

## SpektraLab native Windows engine

https://github.com/JamesQiu2005/SpektraLab at 99c2d5c9883be485085895157279cc7c4eaa8db6. GPL-3.0-or-later. The legacy native host, resources, licenses and material-data attribution are in resources/spectral in the Windows distribution (native/spectral after runtime preparation in a development checkout). The source archive includes the modified engine under SpektraLab-port, LibRaw and Vulkan-Headers dependency sources, and build instructions. These compiled runtime directories are intentionally not tracked in Git.

## Community Windows implementation

Selected native contrast-mask, film-edge/date rasterisation and Vulkan kernels
are adapted from https://github.com/LUOJW5566/SpektraLab at
c14effc0dc665be8712cca433f0a56cf5a506547 (GPL-3.0-or-later).
The legacy engine preserves historical grade and PNG16 host paths for existing recipes. New basic adjustments use LUT mode only.
The embedded TeX Gyre Heros faces used for film-edge lettering are under the
GUST Font License; their notices are included under resources/spectral/licenses in the Windows distribution and in the corresponding source archive.
This integration is not an endorsement by either upstream author.

The full community editor frontend is also embedded, with the dose Electron transport, launch/return hooks and clearer negative/positive direct-output labels. See vendor/spektralab/README.md. Its reference native host is reused unchanged from v1.3.1-windows.1. Its matching source, dependency sources, original component/data licenses, build records and the recorded license-text provenance limitation are included in upstream-release-source/ inside dose-0.29.0-source.zip. The legacy engine and reference host remain separate source/data distributions. Full native corresponding source is available from the same GitHub Release as the binary; see docs/BUILD.md.

## Runtime libraries

- Electron 45.0.0 — MIT; Chromium and its bundled components retain their own licenses. The portable distribution includes LICENSE and LICENSES.chromium.html from Electron.
- Sharp 0.35.5 — Apache-2.0; packaged native libvips and codec dependencies have their own notices in the bundled npm packages.
- Electron Packager and Playwright are development / verification dependencies, not shipped in the runtime app.
- The dose UI uses Windows system fonts. The native film-edge engine embeds TeX Gyre Heros as described above.

## User-supplied color tables

Six bundled Pat David film emulations are CC BY-SA 4.0, with their own attribution and share-alike terms. Source: https://github.com/NatronGitHub/clut at commit af7b50d4caf6244fb6895a647f5b6a84efe7931a. Original PNGs, converted 33³ cube files, attribution, upstream README and modification notice are in assets/luts. License: https://creativecommons.org/licenses/by-sa/4.0/. Film names describe approximations only; no trademark endorsement is implied.

Optional locally generated spektrafilm 0.3.4 color tables originate from Andrea Volpato's project, commit 3bb2c2d2801ff68b92019cf1dbcbb133d60832bc. Those local tables and their SPEKTRAFILM_LICENSE.txt/PROVENANCE are installed separately; that optional Python package and those local LUTs are not bundled (the native SpektraLab engine described above is bundled). Dehancer, RNI and DxO are external commercial products, not embedded engines. LUT-mode grain/halation/bloom is independently implemented by LightTable; spectral mode uses the native SpektraLab effects.

The application implements an original generic 3D .cube reader and trilinear sampler. No Gloam binary, code, or LUT is bundled. The Gloam public showcase YINGZEJUN 5207 LUT retains its author's rights; public availability is not a redistribution license. A locally imported file remains in the user's application data, separate from distributable builds. It is a 16³ web showcase, not a verified reconstruction of the iOS app.

## Audio

The upstream ShutterClick.wav, ShutterClickRoom.wav and ShutterArrivalRoom.wav are NOT included. Their original rights were not granted by the upstream MIT license. This port generates its own short mechanical effects procedurally with Web Audio; no third-party audio samples are used.

## Test photographs

Development-only fixtures were obtained from Lorem Picsum (https://picsum.photos, image IDs 1018, 1015, 1016, 1039, 1043, 1040). They are not included as demo photos in the application or source archive. Delivered verification screenshots may show these test photos and are evidence of the running UI, not original photographic work by this project. User-imported images remain owned by their respective rights holders.

## Publication photographs

The 0.29 README and promotional screenshots feature Japanese daily-life photographs licensed through Unsplash. Individual photographers, original works and film information are listed in [docs/PHOTO-CREDITS.md](docs/PHOTO-CREDITS.md). These photographs retain their own copyright and Unsplash License; the software GPL does not apply to them. Source photographs are not bundled as application assets.

