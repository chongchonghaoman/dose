# 构建 dose

## 日常开发：复用已验证的原生运行时

Windows x64，Node.js 22.12+ / npm，Git。运行原生显影还需要 Vulkan 显卡驱动。

```powershell
git clone https://github.com/chongchonghaoman/dose.git
cd dose
npm ci
npm run prepare:runtime
npm start
```

`scripts/prepare-runtime.ps1` 下载固定的 0.28.0 Windows ZIP，验证 SHA-256 后只解出 `spectral`、`reference`、`reference-editor` 三个资源目录到被 Git 忽略的 `native/`。也可复用已下载的文件：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/prepare-runtime.ps1 -ReleaseZip C:\Downloads\dose-0.28.0-Windows-x64.zip
```

Windows ZIP SHA-256：`b6c0b8fa96d28b42bf523e4a662607034233dd86c3f0c3034590de31ea47fcf6`。

## 编辑器与应用打包

```powershell
npm ci --prefix vendor/spektralab/desktop
npm run build:editor
npm test
npm run test:preferences
npm run package
```

`build:editor` 先检查 TypeScript，再构建显影前端，复制到 `native/reference-editor/`。`package` 输出 `build-output/dose-win32-x64/`，包含三个原生资源目录。它不会编译 C++ 引擎。`build.mjs` 是兼容入口，转到相同的打包脚本。

## 完整原生对应源码

[v0.29.0 Release](https://github.com/chongchonghaoman/dose/releases/tag/v0.29.0) 提供 `dose-0.29.0-source.zip`，SHA-256 见同一 Release 的 `SHA256SUMS.txt`。0.29 的原生运行时沿用 0.28，因此上面的固定运行时准备步骤保持有效。

解压后是 `dose-source/`，各部分对应关系如下：

| 目录 | 用途 |
| --- | --- |
| `LightTable-Windows/` | 0.29.0 发布时的 dose 仓库源码、测试、锁文件与显影前端 |
| `SpektraLab-community/` | 社区编辑器完整快照，包含 dose 的 Electron 适配 |
| `SpektraLab-port/` | 保留旧配方兼容所需的独立 legacy 引擎源码及修改 |
| `spectral-tools/` | LibRaw 0.22.2 与 Vulkan-Headers 对应源码 |
| `upstream-release-source/` | 内置参考 host 的准确对应源码、依赖源码、许可与重建脚本 |
| `tools/` | 发布快照的重建与打包脚本 |

两个引擎的来源分别保留，不能把 legacy 引擎的材料数据与参考 host 的数据混用。

**参考 host：** 内置 `resources/reference/spektralab-host.exe` 与 LUOJW5566/SpektraLab `v1.3.1-windows.1` 的参考文件一致，SHA-256 为 `3cba7a6827cb5f616ddcf8b73cbda194371881c1b2105d274aeb86ddc2311c46`。dose 没有改写这个二进制。其源快照以 `99c2d5c9883be485085895157279cc7c4eaa8db6` 为上游基线，修改记录随源包保存。具体工具版本与调用方法见 `upstream-release-source/README-SOURCE.txt` 和 `reproduce-editor.ps1`。

**Legacy host：** 按 `SpektraLab-port/engine/WINDOWS.md`、`LightTable-Windows/build-spectral.ps1` 与 `LightTable-Windows/SPECTRAL-BUILD.md` 构建。该脚本按源码包的 sibling 目录结构工作，不能直接套用到本 Git 仓库的目录中。

参考 host 的构建涉及 C++20 MinGW、CMake、Vulkan headers、glslang、LibRaw；完整 Tauri 壳的重建还需要 Rust MSVC 与 Windows C++ 工具。精确版本以快照内记录为准。重建后，将各自运行时放回对应 `native/` 目录，再运行 dose 打包命令。

完整对应源码放在 Release；本 Git 树保留日常维护的 dose 代码与显影前端。源码包不包含编译缓存、个人照片或离线工具链。参考源码快照保留了一项许可文本来源说明：`react-remove-scroll-bar 2.3.8` 声明 MIT，补充全文来自上游 master，准确版本的 upstream tag 无法取得，详见 `LICENSE-REVIEW-GAPS.json`。

## 验证

`npm test` 包含 70 项单元测试；`npm run test:preferences` 包含 3 项持久化测试。CI 运行这两组测试与显影前端的类型检查／构建。CI 不代表 GPU、RAW 或界面端到端验收。

桌面验收使用独立用户数据目录：

```powershell
npm run test:fixtures
npm run test:photo-workflow
node tests/lut-panel-desktop.cjs
node tests/reference-editor.cjs
npm run test:magazine-desktop
```

`test:fixtures` 从 Lorem Picsum 下载六张公开测试照片，只写到被 Git 忽略的 `tests/fixtures/`。不会读取个人图库。也可自行提供同名测试文件，见脚本中的清单。显影测试需要先准备运行时；`DOSE_REFERENCE_INPUT` 可指定公开测试输入，`DOSE_REFERENCE_EXTENDED=1` 开启重复编辑与关闭保存检查。

0.29.0 在源码运行和 Windows 成品包中验证了杂志分页、主图、撤销／重做、单页重排、重启恢复，以及实际 JPEG / PNG 按页导出；检查了 1000 像素宽窗口。发布示例另用六张日本日常照片，在成品包里完成三页导出、LUT 预览和原生显影 TIFF 回传。0.28 的单张查看、图库、重复显影与关闭保存验收记录继续保留；DNG、半幅和所有显卡不计作本次重新验证。

