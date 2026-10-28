# GitHub 应用内更新发布

公开版在每次完整启动、台面准备结束后独立检查一次；曾跳过的版本也重新提示。
「运行期间自动检查更新」只控制 Sparkle 每24小时的检查周期，关闭后仍保留启动检查和手动「检查更新…」。
默认只提示；下载、安装并重启由用户点击执行。重启前保存布局。
无更新时后台保持安静，断网时后台不弹错误；手动检查由 Sparkle 显示结果和错误，可重试。

更新源为 GitHub 最新正式 Release 的 `appcast.xml`：
`https://github.com/fuyuan9972-svg/LightTable/releases/latest/download/appcast.xml`。
不是检查每次 Git 提交；草稿或预发布不会替代正式发布。

## 首次启用

v0.1.65 内没有更新组件，现有用户必须手动安装带更新功能的版本一次。
首个提供 `appcast.xml` 的正式 Release 为 v0.1.70。以后每次正式发行都必须同时提供此更新文件。
本机 `LightTable` 构建标记为 development，不启动公开更新；`LightTable-public` 发行包启用更新。

## 准备版本（只在本机执行）

1. 递增 `VERSION`，完成代码与文档，确认音频的作者和来源说明正确。
2. 更新 `docs/releases/v版本号.md`，同时更新 `FeatureGuideState.releaseVersion` 和本版说明卡。参数、配色等无需学习新操作的更新只提供说明；只有新增操作才提供对应操作指引。每次升级后首次打开都必须有对应说明，不能沿用旧版新增功能文案；打包检查会拒绝缺少匹配版本说明的发行包。执行 `bash scripts/check-updates.sh`、`bash scripts/check-feature-guide.sh` 和相关功能检查。
3. 运行 `zsh scripts/prepare-release.sh docs/releases/v版本号.md`。脚本构建发行App、生成带签名的ZIP和appcast，校验音频、架构、版本、完整性及签名，不提交或上传。
4. 到 `dist/releases/v版本号/` 检查四个待上传文件：ZIP、`appcast.xml`、同名Markdown更新说明、`SHA256SUMS.txt`。App只放在ZIP内；不要把音频单独作为Release资源上传。

## 发布（用户批准后手动进行）

1. 使用维护者私有工作区的公开导出工具生成候选，经检查后同步到本仓库；禁止整目录复制开发库或合并私人历史。提交前运行 `python3 scripts/check-source-boundary.py --tree . --git-index .`。源码包含对应 `VERSION`、`Package.resolved`、更新公钥、说明和带单独许可的EDR二进制，不能包含EDR实现或研究资料。
2. 在 GitHub 创建相同版本号的 **Draft Release**，标签如 `v0.1.70`，指向刚提交的源码。
3. 上传上述四个文件后再一次性发布为正式 Release，并标记 Latest。不要先发布空Release，以免更新源暂时缺失；不要勾选预发布。
4. 从一份已安装的旧更新版使用「检查更新…」验收下载、安装及重启，并确认原图库布局仍在。首次v0.1.70没有已发布的旧更新版；可在下一次正式更新时完成这项线上验证。

GitHub 自动生成的 Source code ZIP/TAR 不是安装包。更新源和安装包均须使用 HTTPS。
签名后的 `appcast.xml` 和ZIP不要直接编辑；修改后重新准备签名。
现有发行包仍使用 ad-hoc 本地签名，未经过 Apple 公证；Sparkle的更新签名不等同于Apple开发者签名。首次安装应按系统要求处理，建议将App放入「应用程序」。

## 更新签名密钥

公开配置为 `Configuration/Updates.plist` 中的 `SUPublicEDKey`。
对应私钥由官方 `generate_keys` 保存在本机登录钥匙串，account 为 `fuyuan9972-svg.LightTable.updates`。
发布脚本仅按该 account 使用签名工具，不导出私钥，不创建新钥匙，不覆盖公钥。
妥善备份钥匙串；不要把私钥提交Git或放进GitHub Release。换电脑时按Sparkle官方迁移流程转移密钥。

Fork项目应建立自己的仓库、更新源和签名密钥，不向本项目更新源发布自己的包。

官方参考：
- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/programmatic-setup/
- https://sparkle-project.org/documentation/customization/
- https://sparkle-project.org/documentation/publishing/


## EDR 私有源码边界（2026-10-28）

后续EDR版本必须通过私有工作区的公开导出清单生成候选，禁止整目录同步开发库或合并私人Git历史。公开仓库只接收调用接口、预编译二进制及其单独许可；EDR实现、参数研究和数值参考测试保留私有。发布准备已接入源码及ZIP检查。

本地已启用Distribution/hooks；换机器先运行`git config core.hooksPath Distribution/hooks`。提交前检查实际暂存区，推送前检查待推送提交历史。完整新版源码候选在私有工作区生成和验证，未经发布授权不提交、推送或上传。


维护者须启用提交/推送检查：`git config core.hooksPath Distribution/hooks`。公开基础测试使用`swift test`及仓库内的交互检查；私有光学数值测试由维护者在私有开发区执行，不进入公开源码包。
