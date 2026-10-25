# 依赖、素材与体验来源

## 系统框架

本应用使用 macOS 提供的 SwiftUI、AppKit、Core Image、Core Graphics、Metal、ImageIO 等系统框架。它们由系统或 Apple 开发工具提供，不作为本仓库的第三方源码打包。

## Sparkle 更新组件

应用内更新使用 Sparkle 2.10.0，来自 https://github.com/sparkle-project/Sparkle 。
SwiftPM 固定此版本并校验其二进制包摘要。应用中包含 Sparkle.framework 及原有更新辅助程序。
Sparkle 及其内含组件遵循其各自许可，完整许可随应用保存在 `Contents/Resources/Sparkle-LICENSE.txt`。

## 体验参考

观片台与幻灯机的体验参考实体灯箱、胶片袋及幻灯机，也受到 [SpektraLab 观片台](https://spektralab.app/zh/lighttable/) 的启发。

本应用是独立的 SwiftUI / AppKit 实现。本发行版不打包 SpektraLab 的应用或引擎源码、官网素材、胶片配置、LUT 或品牌标识，与 SpektraLab 没有官方隶属或背书关系。参考来源说明不改变相应原项目和素材的许可。

## 音频与照片

v0.1.65 曾为静音版。v0.1.69 根据项目维护者的明确要求恢复「快门咔嚓」，创作者为 **酸菜鱼**，素材 ID `7046771589660036366`，由维护者通过剪映提供。

本项目并非该录音作者。原录音及裁剪、轻房间反射的派生文件**不适用本仓库代码的 MIT 许可**，其权利归原权利人，适用原素材授权；本项目不额外授予这些音频的独立再分发许可。来源与处理见 [音效说明](docs/audio/快门咔嚓.md)。运行应用不依赖剪映或其缓存。

仓库不附带个人照片、调试截图或录屏；运行时由使用者导入自己的照片。项目的 MIT 许可证不为用户导入的照片或另行添加的第三方素材授予权利。

## 项目代码

本仓库原创代码及随附文档使用根目录 [LICENSE](LICENSE) 中的 MIT 许可证；上述第三方组件与音频除外。
