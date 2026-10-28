# SpektraLab editor in dose

The `desktop/` frontend is derived from [LUOJW5566/SpektraLab](https://github.com/LUOJW5566/SpektraLab), commit `c14effc0dc665be8712cca433f0a56cf5a506547`, itself based on [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab). GPL-3.0-or-later; original notices remain in the source and adjacent LICENSE.

dose adds an Electron transport, launch/return integration and a return toolbar. It also clarifies negative/positive direct-output labels. Film response profiles and the reference native host are not modified by this integration. The `modern_UI/.../Resources` subset holds the original catalog, covers and license texts required by `desktop/scripts/copy-assets.mjs`.

The native reference host is distributed with dose's Windows Release. Its matching source snapshot, third-party dependency archives and build instructions are included in the `upstream-release-source/` folder of `dose-0.28.0-source.zip`. The separate legacy engine source is `SpektraLab-port/` in that archive. See [BUILD.md](../../docs/BUILD.md) for the exact distinction and checksums.
