# dose · Windows 社区引擎集成（2026-10-29）

在 dose 现有光谱处理流程上，选择性合入 LUOJW5566/SpektraLab
windows-community 的 native Windows 实现，来源提交
c14effc0dc665be8712cca433f0a56cf5a506547。

## 可使用的新增功能

选中照片 → 胶片调色 → 光谱流程 →「片边、印字与蒙版」。

- 胶片边缘：原生生成片基、齿孔及胶片标记，适配 135 与 120。
- 日期背印：使用用户明确选择的日期，留空不打印，不推断拍摄日。
- 对比度蒙版：高光与暗部强度可调；全部默认关闭。
- 新参数随照片保存、撤销；JPEG、PNG、TIFF 的原生导出都包含效果。
- 原生片边替代台面的装饰片框，防止双重边框；书页/九宫格内保持比例完整显示。
- 修复 PNG 下拉选择仍进入 JPEG 路径的问题。

保留 dose 的自然显影、自动适配、原有调色、带 ICC 的 PNG16 预览和 TIFF16 输出。
没有修改实测胶片/相纸数据。旧配方不会自动打开新功能。

## 验证与边界

自动测试之外，使用真实照片及 Ricoh GR III DNG 验证 native GPU 处理，
并使用 Electron 原生窗口操作控件、导出 PNG、重启恢复配方。
关闭新增效果后，与升级前同一张照片的像素结果完全一致（固定测试参数）。

本轮未将社区版整个 Tauri 编辑器搬入 dose；半格双图独立编辑、完整曲线/色轮 UI
没有在本轮加入。完整 Cineon DI 调用仍明确拒绝，底层 shader 存在不代表完整工作流可用。
没有声明与 macOS Metal 输出逐像素一致；未验证所有 Windows/GPU 型号。

## 来源与复现

- dose 的现有 SpektraLab 基线：99c2d5c9883be485085895157279cc7c4eaa8db6。
- 社区移植：https://github.com/LUOJW5566/SpektraLab
- 原项目：https://github.com/JamesQiu2005/SpektraLab
- 保留 GPL-3.0-or-later 与材料数据 CC BY-SA 4.0 声明。
- 原生片边字体 TeX Gyre Heros 的 GUST Font License 与来源随程序打包。

构建：准备 SPECTRAL-BUILD.md 描述的工具与依赖，运行 build-spectral.ps1，
然后 npm ci、npm test、node --test tests/community-controls.test.cjs、
node tests/community-native.cjs、node tests/community-desktop.cjs。
后两项需要 Windows Vulkan 显卡；DOSE_COMMUNITY_OUTPUT 可指定验证目录。
DOSE_RAW_FIXTURE 可额外指定自有 RAW。测试图片不包含在应用中。
