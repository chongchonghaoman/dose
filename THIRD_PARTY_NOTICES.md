# 依赖、素材与体验来源

## 系统框架

本应用使用 macOS 提供的 SwiftUI、AppKit、Core Image、Core Graphics、Metal、ImageIO 等系统框架。它们由系统或 Apple 开发工具提供，不作为本仓库的第三方源码打包。

## Sparkle 更新组件

应用内更新使用 Sparkle 2.10.0，来自 https://github.com/sparkle-project/Sparkle 。
SwiftPM 固定此版本并校验其二进制包摘要。应用中包含 Sparkle.framework 及原有更新辅助程序。
Sparkle 及其内含组件遵循其各自许可，完整许可随应用保存在 `Contents/Resources/Sparkle-LICENSE.txt`。

## SHARP 单图场景生成

来源：https://github.com/apple/ml-sharp ，源码提交 `aed6527499ef91cba3b54c18d49a870f25947190`。随附 `src/sharp` 保持上游内容，应用另行提供推理适配代码。

源码许可、模型许可、致谢和来源记录分别位于 `Sources/LightTableApp/Resources/ReturnToPast/sharp-source/` 下的 `LICENSE`、`LICENSE_MODEL`、`ACKNOWLEDGEMENTS` 与 `PROVENANCE.txt`，同时随应用打包在 `Contents/Resources/ReturnToPast/sharp-source/`。

SHARP 模型权重不随仓库或安装包分发，首次使用时从 Apple 提供的地址下载。**模型仅限非商业科学研究，其许可明确排除产品开发或商业产品／服务用途。** 按需下载、本机处理或免费提供应用不改变模型的使用限制；源码许可与模型许可应分别遵守。

## PlayCanvas 与 OOOSplat 场景预览

- PlayCanvas 2.21.4：https://github.com/playcanvas/engine ，MIT 许可。
- OOOSplat：https://github.com/ooolabdev/ooosplat ，提交 `65193513fde9e5cb2bf5bd9b906c7221f834b077`，Apache License 2.0。预览控制及后端相关衍生代码用于离线资源加载、应用生命周期、视角限制与输入降速等适配。

许可全文与修改声明在 `Sources/LightTableApp/Resources/ReturnToPast/viewer-licenses.txt`，随应用保存在 `Contents/Resources/ReturnToPast/viewer-licenses.txt`。以上组件及 SHARP 不纳入本项目原创代码的 MIT 授权。

## 体验参考

观片台与幻灯机的体验参考实体灯箱、胶片袋及幻灯机，也受到 [SpektraLab 观片台](https://spektralab.app/zh/lighttable/) 的启发。

本应用是独立的 SwiftUI / AppKit 实现。本发行版不打包 SpektraLab 的应用或引擎源码、官网素材、胶片配置、LUT 或品牌标识，与 SpektraLab 没有官方隶属或背书关系。参考来源说明不改变相应原项目和素材的许可。

## 音频与照片

v0.1.65 曾为静音版。v0.1.69 根据项目维护者的明确要求恢复「快门咔嚓」，创作者为 **酸菜鱼**，素材 ID `7046771589660036366`，由维护者通过剪映提供。

v0.1.107 另包含维护者通过剪映提供的两份素材：

- 「复古胶片机按键声」，素材 ID `7079262499366833421`，裁剪为约0.552秒的 `SlideChange.wav`，用于幻灯片换片。
- 「放映机放映」，素材 ID `7278467024668462394`，截取开头约3秒为 `ProjectorStart.wav`。该资源保留在包内，当前加载阶段保持静音，不播放此素材。

上述两份素材的作者尚未确认，不在此作作者归属声明。

本项目并非这些录音的作者。原录音及裁剪、轻房间反射的派生文件**不适用本仓库代码的 MIT 许可**，其权利归原权利人，适用原素材授权；本项目不额外授予这些音频的独立再分发许可。来源与处理见 [音效说明](docs/audio/快门咔嚓.md)。运行应用不依赖剪映或其缓存。

仓库不附带个人照片、调试截图或录屏；运行时由使用者导入自己的照片。项目的 MIT 许可证不为用户导入的照片或另行添加的第三方素材授予权利。

## 项目代码

本仓库开源基础代码及随附文档使用根目录 [LICENSE](LICENSE) 中的 MIT 许可证；上述第三方组件、模型与音频除外。


## 第一方 EDR 专有组件

Binaries/LightTableEDR.xcframework（含公开调用头文件）是第一方专有二进制，按Binaries/EDR-LICENSE.txt授权，不纳入根目录MIT许可。安装包保留该许可。其余组件仍分别适用上述许可。
