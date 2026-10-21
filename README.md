# moonflac

纯 MoonBit 实现的 FLAC 无损音频解码器：零 FFI、不依赖任何 C 库或系统编解码器，可编译到 `wasm-gc` / `js` / `native` 三后端。

## 项目目标

把原生 FLAC（`.flac`）解码为 PCM：`moonflac` 只做解码，不包含编码器、标签写入与播放输出。与进程内 FFI 方案（如 `moon_rodio` 的 C 封装）不同，本库可以随项目一起编译进浏览器——这是它存在的核心理由。

## 支持范围（已实现并经差分验证）

按 RFC 9639 交付以下解码能力，全部路径都有**与参考解码器逐样本比对**的自动化测试：

- **元数据**：`fLaC` 魔数、STREAMINFO 全字段、元数据块链遍历（保留块类型按规范拒绝）；
- **帧头**：帧同步、全部块长码（表码 + 8/16 位扩展）、全部采样率码（表码 + 12/13/14 扩展字段）、声道分配码、位深码（4–32 bps）、UTF-8 形变变长帧号/样本号（含可变块长）、CRC-8；
- **子帧**：CONSTANT、VERBATIM、FIXED（阶 0–4）、LPC（阶 1–32，系数精度 1–15、移位 0–31）；
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

- LPC 子帧系数精度字段为 15 时返回 `Unsupported`：ffmpeg 7.1 对该值直接报 `invalid coeff precision`，其语义在本环境无法验证，因此不发布猜测实现。参考编码器不会产出该值（实测 ffmpeg 编码器精度上限为 15，写入字段为 14）。
- `FlacStream::seek` 在无 SEEKTABLE 时为线性推进（正确优先）；按帧号扫描的快速路径留作后续增量。

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

仓库自带两级验证，任何一次改动都应跑全：

```bash
# 1. 单元测试（白盒 29 用例，双后端）
moon test --target wasm-gc
moon test --target js

# 2. 差分测试：现场生成语料，与参考解码器逐样本比对
#    本地需要 ffmpeg（可用 FLAC_FFMPEG=<路径> 指定），CI 使用 apt 安装的 ffmpeg
python3 tools/gen_corpus.py
python3 tools/diff_oracle.py --target wasm-gc
python3 tools/diff_oracle.py --target js
```

（库使用示例已于 2026-10-18 在全新工程 `moon add Xcsa-ee/moonflac` 实拉 0.1.0 复验通过：整流解码、WAV 写出与流式 seek/next 均按上文运行。）

语料矩阵覆盖：8/16/24/32 bps、1/2/6 声道、四种声道分配、四种采样率码、全部子帧类型与预测阶、分区序扫描、LPC 精度 4/9/15、wasted bits、Rice 转义、Rice2、变长帧号与可变块长、多帧长流，以及魔数错误/空文件/中途截断/CRC-8 损坏/CRC-16 损坏五类负例（负例必须报错）。

关键判据做过变异验证：把 CRC-16 覆盖起点、mid/side 还原公式、rice unary 方向、wasted 左移、LPC 算术右移分别改错，单元测试相应变红。

## 生态定位

按 2026-10-16 对 mooncakes.io 全量 3047 个模块的检索，`flac` 关键词唯一命中 `Milky2018/moon_rodio`，其 FLAC 路径是 `decoder/flac_vorbis_native.c` 中 `DR_FLAC_IMPLEMENTATION` 的 C FFI 封装，仅声明 native 目标；本库为纯 MoonBit 实现，无外部导入，可在 `wasm-gc` 下运行。

## 移植或参考说明

本项目为**原创实现**，依据 [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.txt)（Free Lossless Audio Codec，2024-12）从零开发，未移植任何上游源文件。行为参考 [xiph/flac](https://github.com/xiph/flac)（libFLAC，库代码 BSD-3-Clause，见其 `COPYING.Xiph`）与 [mackron/dr_libs](https://github.com/mackron/dr_libs)（dr_flac，public domain / MIT-0），源码未并入本仓库。差分测试的参考解码器为 FFmpeg。

本项目采用 [Apache-2.0](./LICENSE) 许可证。

## 目录结构

| 路径 | 内容 |
|---|---|
| `metadata.mbt` `frame.mbt` | 元数据与帧头解析 |
| `subframe.mbt` `residual.mbt` | 子帧与分区 Rice 残差 |
| `flac.mbt` | 顶层解码编排与声道去相关 |
| `wav.mbt` | WAV 序列化 |
| `cmd/main` | 命令行示例 |
| `tools/` | 差分测试工具链（语料生成 + 逐样本比对） |
