# HEIC / HEIF support

HEIC decoding runs locally in a worker using heic-decode 2.1.0 (ISC) and libheif-js 1.23.5 (LGPL-3.0). No system HEVC extension is required. Original files are not modified. A full-resolution PNG working cache is stored in the application's user-data/heic-cache folder; cache identity includes original path, size and modification time.

This release reads the first still image. Live Photo video, depth data and HDR gain maps are not imported. The decoded working image is 8-bit RGBA, not an archival preservation of the original HDR/wide-gamut encoding. Maximum HEIC input is 256 MB / 60 megapixels. Export formats remain JPEG and PNG.

Upstream code and build instructions:
- https://github.com/catdad-experiments/heic-decode
- https://github.com/catdad-experiments/libheif-js/tree/v1.23.5
- https://github.com/strukturag/libheif

Dependencies are unmodified and pinned by package-lock.json. Their license files are included with the installed modules in the Electron archive. To inspect or replace the decoder, extract resources/app.asar with @electron/asar, replace node_modules/libheif-js with your compatible build, and repack it (preserving the Sharp native-library unpack directory), or rebuild this application's provided source using the commands in docs/BUILD.md. The integrated application's GPL license does not replace third-party licenses. Modification and reverse engineering of the LGPL component for debugging such modifications are permitted under its license.

Validation fixture (not bundled in the application): https://github.com/strukturag/libheif/blob/master/examples/example.heic
Save the raw fixture as tests/heic-fixtures/example.heic before running node tests/heic-desktop.cjs. The test uses an isolated profile and checks import, uppercase HEIF, damaged input, selected-only live editing, JPEG/PNG export, source byte preservation and restart.
