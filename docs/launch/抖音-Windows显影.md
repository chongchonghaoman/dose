# 标题

Windows 上调完胶片色，接着把照片排成杂志页

# 正文

dose 的 Windows 版里，已经内置了 SpektraLab 显影室。选中一张照片，点「胶片显影」，就能搭配胶片和相纸，接着调曲线、颗粒和曝光。

点「完成并返回 dose」，显影结果会另存成 16-bit TIFF。原片和参数都留着，下次还能继续改。这张照片也会回到工作台，和其他照片一起整理。

这次的 0.29，重点更新了杂志排版。我用一组日本日常实拍做了示例，街边店铺、车厢和樱花排成三页。开篇留一张，中间放图组，最后一张收尾。所有页面都铺在台面上，整组一起看。

喜欢的照片可以设为主图，再换构图也会保留它的位置重点。某一页想换排法，可以只重排这一页。纸面只留照片和空白。

排好后直接按页导出 JPEG 或 PNG，长边最高 4800 像素。现在从调色到保存整组版面，都能在 dose 里接着做完。日常试色也有 LUT 同图预览，打开列表就能比较。

下载在 GitHub：chongchonghaoman/dose。进入 Releases，选 Windows-x64.zip，完整解压后运行 dose.exe。包内有显影所需的运行文件，原生显影需要支持 Vulkan 的显卡与驱动。

感谢 SpektraLab 和 Windows 社区版作者的工作，来源、许可和完整对应源码都放在仓库与 Release 里了。觉得用得上，欢迎点个 Star。

# 标签

#SpektraLab #dose #胶片模拟 #摄影杂志 #Windows软件

# 置顶评论

下载：https://github.com/chongchonghaoman/dose/releases/latest

选择 dose-0.29.0-Windows-x64.zip，完整解压后打开 dose.exe。使用中遇到问题可以在仓库提 Issue，附上显卡型号和复现步骤。

配图是实际应用界面与实际导出页面。日本日常示例的摄影师及来源见仓库 docs/PHOTO-CREDITS.md。

# 配图顺序

1. B-01-cover.png — 调完胶片色，接着排成杂志页。
2. B-02-develop.png — 内置的 Windows SpektraLab 显影室。
3. B-03-magazine.png — 排好整组，逐页保存。
4. B-04-download.png — GitHub 下载方式。
