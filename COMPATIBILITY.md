# moonflac 兼容性验收报告

自动生成（`python tools/compat_report.py`），请勿手改。

## 方法与口径

- **本解码器**：`moon run cmd/main` 解码为 WAV，读回样本；
- **FFmpeg**：解码为 f64le 裸流，按 STREAMINFO 位深还原整数，逐样本比对；
- **libFLAC**：`flac -t` 做完整解码 + STREAMINFO MD5 校验；8 的倍数位深另做 `flac -d --force-raw-format` 裸 PCM 逐样本比对（libFLAC 对 12/20 位拒绝 raw 输出，属工具限制，已如实标注）。

## 结果

- 文件总数：88
- 与 FFmpeg 逐样本一致且 `flac -t` 通过：88
- 与 libFLAC 裸 PCM 逐样本一致：82
- 未做 libFLAC 裸 PCM 比对（工具限制）：6

| 文件 | bps | 声道 | 样本/声道 | vs FFmpeg | flac -t | vs libFLAC raw |
|---|---|---|---|---|---|---|
| Prøve.flac | 8 | 1 | 4000 | 一致 | ok | 一致 |
| input-SCPAP.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| input-SCVA.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| input-SCVAUP.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| input-SCVPAP.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| input-SVAUP.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| input-VA.flac | 16 | 2 | 5880 | 一致 | ok | 一致 |
| שלום.flac | 8 | 1 | 9984 | 一致 | ok | 一致 |
| 🤔.flac | 8 | 1 | 8298 | 一致 | ok | 一致 |
| sine16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| noise16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| even16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| scale4_16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| silence16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| ramp16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| step16_2000.flac | 16 | 1 | 2000 | 一致 | ok | 一致 |
| sine16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| noise16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| even16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| scale4_16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| silence16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| ramp16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| step16_20000.flac | 16 | 1 | 20000 | 一致 | ok | 一致 |
| sine16_r8000.flac | 16 | 1 | 3000 | 一致 | ok | 一致 |
| sine16_r88200.flac | 16 | 1 | 3000 | 一致 | ok | 一致 |
| sine16_r192000.flac | 16 | 1 | 3000 | 一致 | ok | 一致 |
| sine16_r48000.flac | 16 | 1 | 3000 | 一致 | ok | 一致 |
| stereo_ch2_16.flac | 16 | 2 | 3000 | 一致 | ok | 一致 |
| stereo_ch6_16.flac | 16 | 6 | 3000 | 一致 | ok | 一致 |
| channels_ch3_16.flac | 16 | 3 | 3000 | 一致 | ok | 一致 |
| channels_ch4_16.flac | 16 | 4 | 3000 | 一致 | ok | 一致 |
| channels_ch5_16.flac | 16 | 5 | 3000 | 一致 | ok | 一致 |
| channels_ch7_16.flac | 16 | 7 | 3000 | 一致 | ok | 一致 |
| channels_ch8_16.flac | 16 | 8 | 3000 | 一致 | ok | 一致 |
| chmode_indep.flac | 16 | 2 | 4000 | 一致 | ok | 一致 |
| chmode_left_side.flac | 16 | 2 | 4000 | 一致 | ok | 一致 |
| chmode_right_side.flac | 16 | 2 | 4000 | 一致 | ok | 一致 |
| chmode_mid_side.flac | 16 | 2 | 4000 | 一致 | ok | 一致 |
| lpc_none.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| lpc_fixed.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| lpc_levinson.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| porder_00.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| porder_02.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| lpcprec_4.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| lpcprec_9.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| lpcprec_15.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| predorder_estimation.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| predorder_2level.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| predorder_search.flac | 16 | 1 | 6000 | 一致 | ok | 一致 |
| noise_bps24.flac | 24 | 1 | 5000 | 一致 | ok | 一致 |
| sine_bps24.flac | 24 | 2 | 2500 | 一致 | ok | 一致 |
| noise_bps32.flac | 32 | 1 | 5000 | 一致 | ok | 一致 |
| sine_bps32.flac | 32 | 1 | 5000 | 一致 | ok | 一致 |
| bps32_midside.flac | 32 | 2 | 5000 | 一致 | ok | 一致 |
| sine_bps12.flac | 12 | 1 | 3000 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| noise_bps12.flac | 12 | 1 | 3000 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| sine_bps20.flac | 20 | 1 | 3000 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| noise_bps20.flac | 20 | 1 | 3000 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| with_meta.flac | 16 | 1 | 3000 | 一致 | ok | 一致 |
| hand_escape_rice.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_sr12.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_sr13.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_sr14.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_utf8_2byte.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_utf8_3byte.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_variable_blk.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_130frames.flac | 16 | 1 | 8320 | 一致 | ok | 一致 |
| hand_bs64.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_bs192.flac | 16 | 1 | 192 | 一致 | ok | 一致 |
| hand_bs256.flac | 16 | 1 | 256 | 一致 | ok | 一致 |
| hand_bs512.flac | 16 | 1 | 512 | 一致 | ok | 一致 |
| hand_bs1000.flac | 16 | 1 | 1000 | 一致 | ok | 一致 |
| hand_bs4608.flac | 16 | 1 | 4608 | 一致 | ok | 一致 |
| hand_wconst_k1.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_wverb_k1.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_wconst_k2.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_wverb_k2.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_wconst_k3.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_wverb_k3.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_fixed_o0.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_fixed_o1.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_fixed_o2.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_fixed_o3.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_fixed_o4.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_rice2.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
| hand_bps4_verbatim.flac | 4 | 1 | 64 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| hand_bps4_constant.flac | 4 | 1 | 64 | 一致 | ok | libFLAC 拒绝 raw 输出（非 8 倍数位深） |
| hand_allblocks.flac | 16 | 1 | 64 | 一致 | ok | 一致 |
