# 观片台 · LightTable

一款本地运行的 macOS 观片应用，模拟反转片灯箱与幻灯机。导入照片，自由摆片、开灯、用放大镜观察，或进入黑底全屏幻灯模式。

A local macOS light table and slide projector for viewing photographs.

## 下载与运行

- 系统要求：**macOS 14 或更新版本**。
- 预编译安装包面向 **Apple Silicon（M 系列芯片，arm64）**；Intel Mac 暂无预编译包，也未验证运行。
- 安装包可在 [GitHub Releases](https://github.com/fuyuan9972-svg/LightTable/releases/latest) 下载。解压后打开「观片台.app」，也可自行拖入「应用程序」。
- **运行应用不需要 Xcode、Swift 或剪映**。开发工具仅用于从源码构建。
- 当前安装包使用 ad-hoc 本地签名，未经过 Apple 公证；首次打开时，macOS 可能提示无法验证开发者。请先确认下载来源，再按系统提示处理；如不希望运行未公证的安装包，可以自行构建。

**v0.1.65 公开版为静音版**：保留收片、出场、黑场和入场动画，不包含第三方快门录音。

## 功能

- 导入照片或文件夹，包含子文件夹；图片解码能力取决于 macOS。
- 从底栏拖片到台面，自由移动、旋转、缩放；平移和缩放整个观片区域。
- 「一键平铺」将图库中的照片重新摆放到台面；**会清空当前散片布局并重新排列**。
- 开关灯与亮度调整，带短暂过曝回落效果。
- 放大镜观察，按住空格凑近，松开退回。
- 胶片袋式相册页与整页摆放。
- 全屏幻灯：黑色背景、居中单张照片、随机播放顺序和机械换片动画；幻灯模式不显示放大镜。
- 布局和预览缓存保存在本机；不修改照片原文件。

## 使用

1. 点击「选择文件夹」或「添加照片」，也可以把照片、文件夹拖入底栏。
2. 将照片拖到台面，或点击「一键平铺」放置全部照片。
3. 开灯观看，通过亮度滑杆调整灯箱；选中照片后可旋转、缩放或移出台面。
4. 切换到放大镜，用鼠标移动取景，按住空格凑近观察。
5. 点击幻灯片按钮进入全屏；按 **↓ / →** 看下一张，按 **↑ / ←** 返回上一张。
6. 点击「返回观片台」或按 **Esc** 退出幻灯，回到原来的台面。

台面清空或移除照片只改变布局，不删除原文件。照片仍从原路径读取，请保留导入文件的位置。

| 快捷键 | 操作 |
| --- | --- |
| ⌘O | 选择照片文件夹 |
| ⇧⌘O | 添加照片 |
| ⌘L | 开灯 / 关灯 |
| A / V | 普通指针 / 放大镜 |
| 按住空格 | 凑近观察；松开退回 |
| ⌘0 | 整理台面并回到全局 |
| Delete | 将选中照片移出台面 |
| ↓ / →、↑ / ← | 幻灯模式下下一张、上一张 |
| Esc | 退出幻灯模式 |

## 从源码构建

需要 macOS 14+、Swift 5.9 或更新版本，以及 Apple Command Line Tools。也可以使用完整 Xcode 提供的工具链。

```sh
xcode-select --install
git clone https://github.com/fuyuan9972-svg/LightTable.git
cd LightTable
swift build
zsh scripts/build-app.sh
```

已有 Command Line Tools 时跳过第一条命令。构建结果是 `dist/观片台.app`；脚本会执行 Release 构建、生成应用包并进行 ad-hoc 本地签名，不会自动安装或运行应用。

历史构建入口 `build_release.sh` 转发到同一个构建脚本。可通过参数指定输出路径：

```sh
zsh scripts/build-app.sh "dist/custom/观片台.app"
```

项目使用 SwiftUI、AppKit、Core Image 和 Metal，SwiftPM 没有第三方软件包依赖。源码可自行编译；目前不声明 Intel 构建或运行已经验证。

## 检查

以下独立检查直接编译生产源码，不需要 XCTest：

```sh
bash scripts/check.sh
bash scripts/check-drops.sh
bash scripts/check-light.sh
bash scripts/check-loupe.sh
bash scripts/check-sleeves.sh
bash scripts/check-closeup.sh
bash scripts/check-albums.sh
bash scripts/check-optics.sh
bash scripts/check-slideshow.sh
```

它们覆盖布局、拖放、灯光、镜片、相册与幻灯状态等逻辑。图形相关检查需要能够使用 macOS 图形框架的环境；检查通过不等于所有设备上的动画流畅度已经实测。

安装完整 Xcode 并选用其工具链后，还可以运行 SwiftPM 测试：

```sh
swift test
```

## 反馈与许可

通过 [Issues](https://github.com/fuyuan9972-svg/LightTable/issues) 报告问题，请附 macOS 版本、芯片型号和复现步骤。提交截图或录屏前，请移除不希望公开的照片及个人信息。

代码采用 [MIT 许可证](LICENSE)。依赖与素材说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。
