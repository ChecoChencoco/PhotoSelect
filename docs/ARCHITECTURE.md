# 源码结构

- `App/Sources/PhotoSelect`：SwiftUI 页面、AppKit 图片画布与目录树、应用状态、可选 GUI 验证工具。
- `App/Sources/PhotoSelectCore`：目录扫描、解码与缓存、SQLite 收藏、文件操作和事务。
- `App/Sources/PhotoSelectChecks`：可执行核心检查，使用合成测试数据。
- `Tools/RAWDecoderProbe/Sources/ProbeCore`：RAW/TIFF 容器读取，本地 package 依赖。
- `Tools/RAWDecoderProbe/Sources/RAWDecoderProbe`：可选 RAW 探测 CLI，非普通应用启动路径。
- `Tools/RAWDecoderProbe/Tests/ProbeCoreChecks`：容器读取检查。
- `scripts/build.py`：独立构建、打包及本地签名；`--checks` 显式运行核心检查。

文件操作采用只读计划、确认、日志与校验后提交。每批记录来源根目录、直接来源路径和目标目录身份；撤销保守恢复，目录清理只允许删除可证明由本批次创建的空目录。SQLite schema 与旧记录兼容，旧数据不自动迁移或改名。

应用标识及偏好名称包含历史 phase1 字样，为兼容既有本机数据而保留；它们不代表当前版本号。
