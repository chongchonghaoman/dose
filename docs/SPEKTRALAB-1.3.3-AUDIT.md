# SpektraLab 安装包逆向核对与 dose 0.16

输入为用户提供的 SpektraLab 1.3.3 / build 18、macOS ARM64 安装包。DMG SHA-256 为 `cf548ed6b83601c468e22430302cab8839fb30f3e5352c6d07a38bf074562c6b`；解包主程序 5,408,608 字节，SHA-256 为 `2db02dc26f885dd99b61e4857a60309b2970130888fa13a619a2c42b692b1664`。哈希用于绑定分析对象，不是对来源或签名可信性的认证。

## 实际分析

使用 [REA 6.8.0](https://github.com/morluto/rea/tree/046c4ce353fabe9eccf3ec43a5f9fc29027db05e) 的安装包/原生调查方法。REA CLI 完成主程序 artifact 与 byte-entropy Evidence；在 WSL Ubuntu 中使用项目级 JDK 21、Ghidra 12.1.4 成功导入、分析 ARM64 Mach-O，枚举 15,692 个函数，并对 RAW 初始化入口做交叉引用与反编译。原始安装包、App bundle 和主程序没有修改或执行。

REA artifact 主 Evidence ID：`ev_63d9979c74a3183a37305b69aa451c98ea2d60876b5d566cc93c7be190834b38`；byte entropy：`ev_5338b3c766842ad4f7d9197bd696af4b04b9628ea8b859ba2b2944fb9debce31`。完整原始记录及 Ghidra 日志保存在任务的 `outputs/REA-SpektraLab-audit` 和 `work/rea-analysis`，发行目录另附关键证据副本。Ghidra 直接输出和 REA Evidence 分别标记，不把直接脚本输出冒充为 REA provider 返回。

## 确认项及集成

| 证据 | 能确认的结论 | dose 处理 |
|---|---|---|
| Ghidra 对 selector `setLocalToneMapAmount:` 的交叉引用：`0x1003bf9c0` → `FUN_1001997c8` | RAW 初始化先建立 CIRAWFilter；draft mode 关闭。在 `param_4 == 0` 分支，将 boost、shadow boost、gamut mapping、local tone map、extended dynamic range 五项置零 | 对照公开源码 ImageDecoder.swift 的线性 RAW 分支。Windows 原生 LibRaw 解码保持 16 位线性路径、关闭自动提亮；不把显示解码结果作为胶片处理输入 |
| 同一函数中的 lens correction 和 neutral temperature/tint 分支 | 镜头校正取决于 flag 和能力支持；白平衡写入受另一 flag 控制 | 保留 LibRaw 相机白平衡路径；不宣称已经复刻 Apple 镜头校正或 CIRAWFilter 的逐像素结果 |
| 正式包与公开源码的材料核对 | 33 份材料 JSON 语义相同，光谱常量逐字节相同；产品数据已包含 24 胶片、9 相纸/拷贝片 | 沿用已整合的公开源码数据与来源说明，不直接打包 Mac 可执行文件/私有系统框架 |
| 同图 Windows 原生复现：旧 dose 自动适配会给已测光结果叠加负 EV 和饱和度缩减 | 压暗与层次损失存在于 dose 新加的成片辅助层 | 0.16 默认关闭并备份停用旧补偿；可选 v2 仅有限提亮、不自动降饱和度，实际渲染检查暗部/中间调/剪切后才保存 |

反编译中的布尔参数名是结合公开源码作出的映射；二进制本身保留的是参数和分支。仅凭该函数不能证明每一个 caller 传入的 flag 默认值，也不能把分支能力等同于整条产品路径的运行观测。

## 验证与剩余差异

0.16 重新执行四个同源输入的原生处理/独立 Layer 2 公式核对；RGBA16 工作图与既有独立参数 Windows 参考一致。亮度检查覆盖 20 款彩色胶片和多个场景。Apple DNG 原尺寸 TIFF16、ICC/P3 显示、连续预览、所选照片范围、旧补偿字节备份及重启保存均有独立报告。87 个原生运行文件与 0.13 逐字节相同，修复位于应用辅助层。

未执行 macOS Metal/ColorSync，未获得同图原版导出的运行样本，因此不宣称完整产品逆向、所有函数理解完成或 Mac/Windows 成片逐像素一致。RAW 去马赛克、Apple 镜头校正、系统色彩管理仍有平台差异；DI、场景纬度、局部蒙版等也不在当前已开放功能范围。后续核对应从这些明确边界继续，不重新猜测材料数据是否缺失。
