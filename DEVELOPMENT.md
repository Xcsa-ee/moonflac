# 开发回顾（DEVELOPMENT.md）

本文回答三个问题：**为什么这样设计**、**哪些环节用了 AI**、**参考了什么、边界在哪**。
所有数字都能在仓库内用命令复现，本文不写无法验证的结论。

## 1. 项目定位与边界

`moonflac` 是 RFC 9639（FLAC）原生解码器的纯 MoonBit 实现：零 FFI，不链接 libFLAC，
可编译到 `wasm-gc` / `js` / `native`。

**不做**（写进 README「明确不做」，不是遗漏）：FLAC 编码器、标签（ID3 / Vorbis Comment）读写、
Ogg 封装的 FLAC、重采样 / 混音 / 音频设备输出。这些属于"另一条产品线"，混进来会让
"位精确解码 + 归档校验"这个定位失焦。

## 2. 关键架构决策

| 决策 | 备选方案 | 为什么选它 | 代码位置 |
|---|---|---|---|
| **位流与字节流双视图**：位读取器只管按位取值，CRC 校验直接按帧的原始字节区间算 | 边读位边更新 CRC（省一次遍历） | 边读边算会把"读了多少位"和"CRC 覆盖到哪个字节"耦合在一起，帧头/子帧出错时很难判断是位对齐错还是校验错；分开后 `crc8_range(br.data, start, end)` 是纯函数，易测 | `frame.mbt:18,205-208` |
| **变长帧号自己实现**，不复用标准 UTF-8 解码器 | 复用 `moonbitlang/x` 的 UTF-8 解码 | FLAC 的帧号是"UTF-8 形变"：允许最长 36 位、字节布局相同但语义不同。复用标准解码器会把合法帧判成非法 | `frame.mbt:59-86` |
| **样本域全程 Int64** | 按位深用 Int / Int32 | 32 bps 下 side 声道是 33 位，mid/side 还原还要再左移 1 位；wasm-gc 的 32 位 Int 会静默溢出，这类 bug 只在极少数文件上出现，测不到就等于没有 | `subframe.mbt:9-13`、`flac.mbt:5-6` |
| **mid/side 补回丢失的最低位** | 直接 `mid*2` 还原 | 编码端 `mid` 是 `(l+r)>>1`，丢了 LSB；用 `side` 的最低位补回才能逐样本一致（`mid' = (mid<<1) \| (side&1)`） | `flac.mbt:112` |
| **错误分类里不设"合法但未实现"** | 保留一个 `Unsupported` 变体兜底 | 有兜底变体时，"未实现"会悄悄吃掉真 bug。规范标 forbidden 的值（LPC 精度字段 `0b1111`、块长 65536、保留子帧类型等）一律判非法 | `flac_error.mbt`、`subframe.mbt:68-76`、`frame.mbt`（块长上限 65535） |
| **三级验证而不是只堆单测** | 只写单元测试 | 单测只能验证"我以为的规范"；必须有一个独立实现（FFmpeg）逐样本对拍，再加 libFLAC 的 `flac -t` 做 MD5 级校验，才能覆盖"两边都错但错得一样"之外的场景 | `tools/diff_oracle.py`、`tools/compat_report.py` |

## 3. 验证体系（当前数字）

| 层级 | 命令 | 当前结果 |
|---|---|---|
| 单元测试（白盒） | `moon test --target wasm-gc` / `--target js` | 各 **63 / 63** 通过 |
| 差分测试（FFmpeg 逐样本） | `python tools/diff_oracle.py --target wasm-gc` | **85 通过 / 0 失败**（79 正例 + 6 负例） |
| 兼容性报告（三方） | `python tools/compat_report.py --xiph <xiph>/test/flac-to-flac-metadata-test-files --corpus tools/corpus` | **88 个文件**全部与 FFmpeg 逐样本一致 + `flac -t` 通过；其中 82 个另通过 libFLAC 裸 PCM 比对 |
| CI | `.github/workflows/ci.yml` | fmt / check `--deny-warn` / build / 双后端测试 / 差分 / 对拍 / wasm 冒烟 |

判据为什么这样定：
- **逐样本而不是只看时长/波形**：解码器常见的错误是"听不出但数值错"，逐样本比较才能抓到；
- **两个 oracle 而不是一个**：FFmpeg 与 libFLAC 是不同的实现，两者都过才排除"同一个错误假设"；
- **负例必须报错**：魔数错误、空文件、中途截断、CRC-8/CRC-16 损坏、MD5 篡改六类，`tools/corpus` 里各有一个文件。

## 4. 参考来源与边界

| 参考对象 | 许可 | 用到什么 | 没用到什么 |
|---|---|---|---|
| [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.txt) | IETF RFC 文本条款 | 格式定义、强制校验项 | — |
| [xiph/flac](https://github.com/xiph/flac)（libFLAC） | 库 BSD-3-Clause；`flac` 工具 GPLv2 | 行为对照、错误分类取舍、`flac -t` 作第三方校验器 | 未取源码、未链接、未复用 API/数据结构 |
| [mackron/dr_libs](https://github.com/mackron/dr_libs)（dr_flac） | public domain / MIT-0 | 帧头损坏后的重同步策略 | 未取源码、未移植 API |
| [FFmpeg](https://ffmpeg.org/) | LGPL/GPL（按构建） | 仅作差分测试 oracle | 不参与实现、不进仓库 |

测试素材：xiph 官方测试文件按 tag `1.5.0`（commit `1507800d`）在 CI 现场 clone、不随仓库再分发；
自建语料由 `tools/gen_corpus.py` 现成生成（ffmpeg 编码 + 手造帧），`tools/corpus/` 不入库；
仓库只带一个 9 KB 最小样例 `examples/sample.flac`。

## 5. AI 参与说明

本项目在开发过程中使用 AI 编码助手（DeepSeek）作为主要编码工具，分工如下：

| 环节 | AI 参与 | 人工负责 |
|---|---|---|
| 规范研读 | 从 RFC 9639 提取字段表、码值表与强制校验项，整理成实现清单 | 判定哪些是 MUST / MUST NOT，复核引用章节 |
| 核心实现 | 按清单产出 `.mbt` 初稿（位读取、帧头/子帧/残差、声道去相关、MD5） | 架构取舍（上表六项）、代码 review、错误分类口径 |
| 测试与工具 | 单测骨架、`tools/*.py` 语料生成与对拍脚本 | 判据选择（为什么 FFmpeg + libFLAC 双 oracle）、验收 |
| 文档 | README / COMPATIBILITY / CHANGELOG 初稿 | 对外数字与措辞复核 |

**边界**：AI 的输出不作为证据。仓库里每个对外数字都由 `moon test`、`tools/*.py` 或 CI 产生，
可当场复现；依赖只有 `moonbitlang/x`；未并入任何上游源码（`git ls-files` 里没有 `.c/.h/.cpp`）。
README 里曾有一处"变异验证"的说法因为没入库脚本而改写为"人工做过、未入库"——
宁可把口径收小，也不留无法证伪的断言。

## 6. 已知取舍

- **native 后端未做端到端验证**：`moon check --target native` 通过，但 `build` 需要系统 C 工具链；
  CI 只跑 `wasm-gc` / `js`（见 README「已知限制」）。
- **无 SEEKTABLE 时 `seek` 是线性推进**：正确优先，快速路径留作后续增量。
- **`COMPATIBILITY.md` 由脚本生成、手工提交**：CI 每次重新生成并打印关键行，但没有把新报告提交回仓库；
  需要时用本地命令重跑（本仓库 2026-10-30 的重跑结果与仓库内版本逐行一致）。

## 7. 复现

```powershell
cd moonflac
moon fmt --check
moon check --target wasm-gc --deny-warn
moon test --target wasm-gc      # 63 / 63
moon test --target js           # 63 / 63
moon run cmd/main -- examples/sample.flac output.wav
python tools\diff_oracle.py --target wasm-gc
```
