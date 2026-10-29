# moonflac

纯 MoonBit 实现的 FLAC 无损音频解码器：零 FFI、不依赖任何 C 库或系统编解码器，可编译到 `wasm-gc` / `js` / `native` 三后端（CI 验证 `wasm-gc` 与 `js`；`native` 需 MSVC/系统链接器，见「已知限制」）。

## 项目目标

把原生 FLAC（`.flac`）解码为 PCM：`moonflac` 只做解码，不包含编码器、标签写入与播放输出。与进程内 FFI 方案（如 `moon_rodio` 的 C 封装）不同，本库可以随项目一起编译进浏览器——这是它存在的核心理由。

## 支持范围（已实现并经差分验证）

按 RFC 9639 交付以下解码能力，全部路径都有**与参考解码器逐样本比对**的自动化测试：

- **元数据**：`fLaC` 魔数、STREAMINFO 全字段、元数据块链遍历（保留块类型按规范拒绝）；
- **帧头**：帧同步、全部块长码（表码 + 8/16 位扩展，块长上限 65535；65536 按 RFC 9639 §9.1.6 拒绝）、全部采样率码（表码 + 12/13/14 扩展字段）、声道分配码、位深码（4–32 bps）、UTF-8 形变变长帧号/样本号（含可变块长）、CRC-8；
- **子帧**：CONSTANT、VERBATIM、FIXED（阶 0–4）、LPC（阶 1–32，系数精度 1–15、预测右移按 s(5) 解释即 -16..15，负值为左移）；
- **残差**：熵编码方法 0/1（Rice 4 位参数 / Rice2 5 位参数）、任意分区序、分区参数与数据交错、**参数转义**（15/31 → 5 位原码位宽）、wasted bits；
- **声道去相关**：left/side、right/side、mid/side（side 位宽恒为 bps+1，含 32 bps 下的 33 位）；
- **容错**：帧头级损坏向后扫描重同步；子帧/CRC-16 损坏返回结构化错误（绝不 panic）；`total_samples` 已知时输出精确截断、不足报错；
- **输出**：planar PCM 接口 + WAV 序列化（8/16/24/32 容器，12/20 位高位对齐左移）；
- **流式与定位**：`FlacStream` 逐块解码（不一次性物化整条流）；`seek` 按 SEEKTABLE 跳帧，
  无点表时从流起点线性推进；
- **元数据读取**：`read_seektable` / `read_vorbis_comment` / `read_picture` /
  `read_application` / `read_cuesheet`（CUESHEET 全字段：目录号、ISRC、轨道、索引点，
  保留位按规范强制校验为零）；
- **增量输入**：`FlacFeeder` 支持按任意块大小边喂边解（`feed`/`next`/`finish`），
  数据不足时等待更多输入而不误报错误；
- **完整性**：STREAMINFO 记录了 MD5 时对解码 PCM 做 MD5 校验（交织小端、每样本符号扩展到
  `ceil(bps/8)` 字节，符合 RFC 9639 §8.4，覆盖 4–32 全位深；8/16/24/32 位的打包方式此前已与
  ffmpeg 写入值交叉验证，非 8 倍数位深按规范原文实现），不符报 `Md5Mismatch`。

## 明确不做

- FLAC **编码器**（只解码）；
- 标签（ID3/Vorbis Comment）读写；
- Ogg 封装的 FLAC（`Ogg FLAC`）；
- 重采样、混音、音频设备输出。

## 已知限制

- LPC 系数精度**支持 1–15 bit 全档**（精度字段 0..14）。字段值为 `0b1111` 时按
  RFC 9639 Table 22 的 "0b1111 is forbidden" 判为非法码流，报 `BadSubframe`——
  这不是"未实现的合法编码"，符合规范的编码器不会产出它
  （实测 ffmpeg 编码器精度上限为 15，写入字段 14）。
- `FlacStream::seek` 在无 SEEKTABLE 时为线性推进（正确优先）；按帧号扫描的快速路径留作后续增量。
- **`native` 后端未做端到端验证**：`moon check --target native` 通过（类型检查层面），但
  `moon build --target native` 在 Windows 上需要 MSVC Build Tools（C++ 工具 + Windows SDK），
  在 macOS/Linux 需要可用的系统 C 工具链；本项目 CI 只在 ubuntu 上跑 `wasm-gc` 与 `js` 两个后端，
  native 的构建与测试以使用者本地环境为准。
- **示例输入不在仓库内**：`tools/corpus/` 已被 `.gitignore` 排除，语料用
  `python3 tools/gen_corpus.py` 现场生成（需 ffmpeg 与 libFLAC 的 `flac`），见「验证方法」。

## 安装

```bash
moon add Xcsa-ee/moonflac
```

## 用法

### 命令行（可运行示例）

```bash
moon run cmd/main -- input.flac output.wav
```

成功时输出采样率、声道、位深与样本数并写入 WAV；失败时输出结构化错误：

```
采样率: 44100 Hz, 声道: 1, 位深: 16, 样本: 2000
已写入: output.wav
解码失败: Xcsa-ee/moonflac.FlacError.BadCrc(kind="CRC-16", ...)
```

### 作为库使用

```moonbit
import {
  "Xcsa-ee/moonflac",
}

// 整流解码
let file = @moonflac.decode(data) // raise FlacError
let wav = @moonflac.wav_encode(
  file.channels,
  file.info.bits_per_sample,
  file.info.sample_rate,
)

// 流式解码 + 定位
let s = @moonflac.FlacStream::new(data)
s.seek(44100) // 跳到第 1 秒
let block = s.next() // Option：每声道一个块的样本
```

`file.channels` 为 planar 布局：`channels[声道][样本]`，样本值在 `file.info.bits_per_sample` 位有符号范围内。流式 `next` 同样返回 planar 块。

## 验证方法（可复现）

仓库自带三级验证，任何一次改动都应跑全：

```bash
# 1. 单元测试（白盒 63 用例，双后端）
moon test --target wasm-gc
moon test --target js

# 2. 差分测试：现场生成语料，与 FFmpeg 逐样本比对
#    本地需要 ffmpeg 与 libFLAC 的 flac（可用 FLAC_FFMPEG / FLAC_BIN 指定路径），
#    CI 使用 apt 安装的 ffmpeg + flac
python3 tools/gen_corpus.py
python3 tools/diff_oracle.py --target wasm-gc
python3 tools/diff_oracle.py --target js

# 3. 兼容性验收报告：xiph 官方测试文件 + 自建语料，
#    三方（本解码器 / FFmpeg / libFLAC）逐样本与 STREAMINFO MD5 比对
python3 tools/compat_report.py \
    --xiph <xiph/flac 仓库>/test/flac-to-flac-metadata-test-files \
    --corpus tools/corpus --out COMPATIBILITY.md
```

当前结果见 [COMPATIBILITY.md](./COMPATIBILITY.md)：88 个文件（xiph 官方 9 + 自建 79）
全部与 FFmpeg 逐样本一致并通过 `flac -t` 的 MD5 校验；其中 82 个另通过 libFLAC
裸 PCM 逐样本比对，其余 6 个（4/12/20 位）因 libFLAC 拒绝非 8 倍数位深的 raw
输出而不做该项（已在报告中如实标注）。

（库使用示例已于 2026-10-18 实拉 0.1.0、2026-10-21 实拉 0.2.0 在全新工程复验通过：整流解码、WAV 写出、流式 seek/next 与 `FlacFeeder` 增量输入均按上文运行。2026-10-29 又在全新工程 `moon add Xcsa-ee/moonflac` 实拉 0.3.0 通过：`decode_flac_base64` 对合法 FLAC 返回非空 base64 WAV、对坏输入按契约返回空串，`wav_encode` 签名与上文一致；该次复验未覆盖流式接口。）

语料矩阵覆盖：4/8/12/16/20/24/32 bps（12/20 位为 libFLAC 真实编码，4 位无参考编码器、
为手造帧）、1–8 声道、四种声道分配、四种采样率码、全部子帧类型与预测阶、分区序扫描、
LPC 精度 4/9/15、wasted bits、Rice 转义、Rice2、变长帧号与可变块长、多帧长流，以及
魔数错误/空文件/中途截断/CRC-8 损坏/CRC-16 损坏/MD5 篡改六类负例（负例必须报错）。

关键判据做过**人工变异验证**（开发期逐项改错后跑单测确认变红，该过程未入库为脚本）：把 CRC-16 覆盖起点、mid/side 还原公式、rice unary 方向、wasted 左移、LPC 算术右移分别改错，单元测试相应变红。

## 生态定位

按 2026-10-16 对 mooncakes.io 全量 3047 个模块的检索，`flac` 关键词唯一命中 `Milky2018/moon_rodio`，其 FLAC 路径是 `decoder/flac_vorbis_native.c` 中 `DR_FLAC_IMPLEMENTATION` 的 C FFI 封装，仅声明 native 目标；本库为纯 MoonBit 实现，无外部导入，可在 `wasm-gc` 下运行。

2026-10-21 起生态新增 `Sakuraqwq1/moonaudio`（多格式音频工具箱，含 FLAC 解码）。两者定位不同：moonaudio 面向 DSP 流水线，输出归一化 `Double`、MD5 仅展示不校验、SEEKTABLE/CUESHEET/PICTURE 块只跳过不解析、无 seek 与增量输入；本库面向位精确解码与归档校验——整数 PCM/WAV 输出、4–32 位深 STREAMINFO MD5 校验、真实增量流式输入、SEEKTABLE seek 与全部元数据块内容解析。本库核心实现（0.1.0 于 2026-10-18 发布）早于 moonaudio 仓库创建（2026-10-21），为独立实现。

## 移植或参考说明

本项目为**原创实现**，依据 [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.txt)（Free Lossless Audio Codec，2024-12）从零开发，未移植任何上游源文件。行为参考 [xiph/flac](https://github.com/xiph/flac)（libFLAC，库代码 BSD-3-Clause，见其 `COPYING.Xiph`）与 [mackron/dr_libs](https://github.com/mackron/dr_libs)（dr_flac，public domain / MIT-0），源码未并入本仓库。差分测试的参考解码器为 FFmpeg。

本项目采用 [Apache-2.0](./LICENSE) 许可证。

## 目录结构

| 路径 | 内容 |
|---|---|
| `metadata.mbt` `frame.mbt` | 元数据块链与帧头解析 |
| `metadata_ext.mbt` | SEEKTABLE / VORBIS_COMMENT / CUESHEET / PICTURE / APPLICATION 内容解析 |
| `subframe.mbt` `residual.mbt` | 子帧与分区 Rice 残差 |
| `flac.mbt` | 顶层解码编排与声道去相关 |
| `bitreader.mbt` `crc.mbt` | 位级读取（含 UTF-8 形变变长帧号）与 CRC-8/16 |
| `stream.mbt` `incremental.mbt` | `FlacStream` 逐块/seek 与 `FlacFeeder` 增量输入 |
| `wasm_api.mbt` `wav.mbt` | base64 导入导出的 wasm 调用面与 WAV 序列化 |
| `flac_error.mbt` | 结构化错误类型 |
| `cmd/main` | 命令行示例 |
| `tools/` | 差分测试工具链（语料生成 + 逐样本比对 + 兼容性报告 + wasm 冒烟） |
