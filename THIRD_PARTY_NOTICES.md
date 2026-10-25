# 依赖、素材与体验来源

## 系统框架

本应用使用 macOS 提供的 SwiftUI、AppKit、Core Image、Core Graphics、Metal、ImageIO 等系统框架。它们由系统或 Apple 开发工具提供，不作为本仓库的第三方源码打包。

`Package.swift` 仅声明本项目自身的 target，没有第三方 SwiftPM 软件包依赖。

## 体验参考

观片台与幻灯机的体验参考实体灯箱、胶片袋及幻灯机，也受到 [SpektraLab 观片台](https://spektralab.app/zh/lighttable/) 的启发。

本应用是独立的 SwiftUI / AppKit 实现。本发行版不打包 SpektraLab 的应用或引擎源码、官网素材、胶片配置、LUT 或品牌标识，与 SpektraLab 没有官方隶属或背书关系。参考来源说明不改变相应原项目和素材的许可。

## 音频与照片

v0.1.65 公开版为静音版，不包含剪映「快门咔嚓」及其裁剪、混响等派生录音，也不依赖剪映缓存。

仓库不附带个人照片、调试截图或录屏；运行时由使用者导入自己的照片。项目的 MIT 许可证不为用户导入的照片或另行添加的第三方素材授予权利。

## 项目代码

本仓库代码及随附文档使用根目录 [LICENSE](LICENSE) 中的 MIT 许可证。
