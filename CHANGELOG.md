# 变更记录

本文件记录已发布到 mooncakes 的版本；`[未发布]` 段落列出已在 `master` 上但尚未发版的内容。
格式参考 Keep a Changelog；版本号遵循 `MAJOR.MINOR.PATCH`。

## [0.3.3] - 2026-10-31

### 文档与仓库
- 仓库内新增最小样例 `examples/sample.flac`（9 KB，44.1 kHz / 16 bit / 单声道 / 2000 样本），
  README 的 CLI 示例改为 clone 后即可原样执行。
- README 补 Windows 说明（`python3` → `python`）与 xiph 测试集的完整 clone 命令（pin 到 tag 1.5.0）。
- 清理三处指向仓库外文件（`tasks/…`）的悬空引用。
- 新增 `DEVELOPMENT.md`（开发回顾：架构决策、验证判据、参考边界、AI 参与说明）。

### 测试
- **变异验证脚本化**：新增 `tools/mutation_check.py`，CRC-16 覆盖起点、mid/side 补最低位、
  wasted bits 左移、LPC 预测右移 s(5)、Rice unary 方向、块长上限 6 个判据逐个改错并断言单测变红；
  本机 6/6 全抓到（约 8 秒），CI 已加同名步骤。
- README 顶部加 CI badge。

### 其他
- 新增 `.gitattributes`，统一 LF 行尾（`*.flac` 等二进制不转行尾）。
- 无解码代码变更。

## [0.3.2] - 2026-10-29

### 文档
- README 新增「来源与许可」四行表：逐项写明参考范围（libFLAC / dr_flac / FFmpeg / RFC 9639）与未移植部分。
- 测试素材写清来源与许可：xiph 官方测试文件按 tag `1.5.0`（commit `1507800d`）clone，不随仓库再分发。
- 补对拍参考解码器版本口径：本地 libFLAC 1.5.0，CI 的 `flac` 由 apt 提供（实测 1.4.3）。
- 无代码变更。

## [0.3.1] - 2026-10-29

### 修复
- LPC 预测右移按 RFC 9639 Table 22 的 `s(5)` 解释：字段值 `>= 16` 表示负数（预测左移），
  合法范围 `-16..15`；此前按无符号 0–31 处理。
- 块长上限收紧为 65535：RFC 9639 §9.1.6 禁止 65536，遇到即报 `BadFrameHeader`。

### 测试
- 补位深码 3（保留值）的判别性用例。

### 文档
- README 口径对齐代码：用例数 63、LPC 右移 `s(5)`、块长 65535、native 后端限制、目录表补全 7 个文件。

## [0.3.0] - 2026-10-27

### 变更
- LPC 系数精度字段 `0b1111` 按 RFC 9639 Table 22（"0b1111 is forbidden"）判为非法码流，
  错误类型归为 `BadSubframe`；删除 `Unsupported` 变体——错误类型里不再存在"合法但未实现"这一类别。

## [0.2.0] - 2026-10-21

### 新增
- `FlacFeeder` 增量输入：按任意块大小边喂边解（`feed` / `next` / `finish`），数据不足时等待而不误报。
- 4–32 位深 STREAMINFO MD5 校验（RFC 9639 §8.4），含非 8 倍数位深的符号扩展与打包。
- `CUESHEET` 全字段解析（目录号、ISRC、轨道、索引点，保留位强制校验为零）。
- 兼容性验收报告工具链（`tools/compat_report.py`）：本解码器 / FFmpeg / libFLAC 三方对拍。

### 修复
- 保留元数据块类型被误拒。
- 帧头解析在数据不足时的截断误报。

### 测试
- 语料扩展到声明范围：位深 4–32、声道 1–8。

## [0.1.1] - 2026-10-18

### 文档
- 修正 README 示例包名（`LL728/moonflac` → `Xcsa-ee/moonflac`）。

## [0.1.0] - 2026-10-18

### 新增
- RFC 9639 解码核心：元数据块链、帧头（含 UTF-8 形变变长帧号）、
  子帧（CONSTANT / VERBATIM / FIXED / LPC）、分区 Rice / Rice2 残差、声道去相关、WAV 序列化。
- 流式解码与 `seek`、元数据块内容读取（SEEKTABLE / VORBIS_COMMENT / PICTURE / APPLICATION）。
- wasm 导出接口（base64 FLAC → base64 WAV）与命令行工具。
- ffmpeg 差分测试工具链与语料生成脚本；CI（双后端测试 + 差分 + 烟雾）。
