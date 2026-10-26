# PhotoSelect

面向 macOS / Apple Silicon 的本地照片浏览与选片应用。当前源码版本 **0.2.2**，采用 SwiftUI、AppKit 和 SQLite；无账户、云图库或网络后台服务。

## 功能

- 文件夹目录树、缩略图和胶片栏，支持 Sony ARW、JPEG、PNG、HEIC、TIFF 图片浏览。
- RAW 预览区分内嵌 JPEG、清晰预览和完整像素解码；实际支持取决于系统解码器及相机格式。
- M / 心形选片，SQLite 保存标记；已选片的组禁止在应用内删除。
- 每次删除均需确认，进入 macOS 废纸篓。
- 完成选片时移动或复制到独立时间码目录；同名自动编号，不覆盖文件。
- 撤销恢复直接来源路径，仅清理本轮新建且为空的目录；有新增内容则保留。

## 构建与运行

要求 macOS 15+、Apple Silicon、Swift 6.0+ 工具链以及 Python 3。开发版本曾使用 Swift 6.1.2；需先安装 Xcode 或 Xcode Command Line Tools，并确保 `swift`、`xcrun`、`codesign` 可用。不支持 Windows、Linux 或 Intel Mac。

克隆仓库并构建：

```bash
git clone https://github.com/ChecoChencoco/PhotoSelect.git
cd PhotoSelect
python3 scripts/build.py
open Build/PhotoSelect.app
```

依赖 `Tools/RAWDecoderProbe` 是仓库内的本地 Swift package，无第三方包下载。脚本默认 release/arm64，生成本地 ad-hoc 签名应用；这不是 Apple 公证的发行安装包。构建产物和日志写入忽略目录，不提交 Git。

可选参数：

```bash
python3 scripts/build.py --configuration debug
python3 scripts/build.py --work /tmp/photoselect-build
```

## 测试

普通构建不运行文件操作测试。需要验证时显式执行：

```bash
python3 scripts/build.py --checks
```

核心检查在全新 UUID 临时目录中生成合成文件，测试移动、复制、冲突、收藏、撤销及目录清理；**复制撤销会将合成副本送入系统废纸篓**。不会读取真实 RAW 样张。受限环境若禁止废纸篓操作，测试会失败，不会退化成永久删除。不要以管理员身份运行。

历史 GUI 验证工具保留在源码中，依赖额外的人工准备样张，不属于默认构建或核心检查。详见 [测试说明](docs/TESTING.md)。

## 使用

1. 从主页添加照片目录；先使用可丢弃副本体验文件操作。
2. 左右键翻页；M 切换选片；F 适应窗口；Z 查看完整像素；Esc 返回浏览页。
3. “完成选片”→“是”后输出到原照片根目录的 `MM月DD日_HH时mm分_选片`，同分钟追加编号。
4. “更多”→“撤销最近一次整理”。从结果目录继续筛选时依赖本机保存的来源记录。

## 限制与数据安全

跨卷移动暂不支持；不明来源的旧选片目录会阻止整理。中断事务会保守阻止继续写操作，尚无完整自动恢复界面。外盘断连、各种相机 RAW、深色和窄窗等场景并未全部验证。视频支持不属于本版本交付范围。

照片留在本机。数据库及操作诊断保存在 `~/Library/Application Support/PhotoSelect/`，包含文件路径，不应公开上传；不要随意删除数据库来绕过恢复保护。RAW 原件、截图、数据库和测试输出不随源码提供。

## 参与与许可证

见 [贡献说明](CONTRIBUTING.md)、[安全反馈](SECURITY.md) 和 [架构说明](docs/ARCHITECTURE.md)。

本项目采用 [MIT License](LICENSE)。Copyright (c) 2026 陈可Checo。
