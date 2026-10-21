// wav.mbt
//
// PCM WAV（RIFF）序列化。容器位宽取 8/16/24/32 中不小于 bps 的最小值，
// 非 8 倍数位深（4/12/20 等）的样本一律按高位对齐左移
// （WAV PCM 只有 8 的倍数位宽，左对齐是无损表示，与 ffmpeg 解出的
// 32 位左对齐值同口径）。
// 纯函数，不涉及文件 I/O，CLI 与后续 wasm 示例共用。

///|
/// 需要的 PCM 容器位宽（8 的倍数）。
fn wav_container_bits(bits_per_sample : Int32) -> Int32 {
  if bits_per_sample <= 8 {
    8
  } else if bits_per_sample <= 16 {
    16
  } else if bits_per_sample <= 24 {
    24
  } else {
    32
  }
}

///|
/// 把 planar 样本序列化为 WAV 字节。8 位容器按 WAV 惯例存无符号值，
/// 其余容器存有符号小端二补码；样本超位宽会先被视图限制在合法范围内
/// （解码器保证样本本身在 bps 位宽内）。
pub fn wav_encode(
  channels : Array[Array[Int32]],
  bits_per_sample : Int32,
  sample_rate : Int32,
) -> Bytes {
  let nch = channels.length()
  if nch == 0 || bits_per_sample < 1 || bits_per_sample > 32 {
    return b""
  }
  let frames = channels[0].length()
  let container = wav_container_bits(bits_per_sample)
  let shift = container - bits_per_sample
  let block_align = nch * (container / 8)
  let data_size = frames * block_align
  let buf = @buffer.Buffer()
  // RIFF 头
  buf.write_bytes(b"RIFF")
  buf.write_uint_le((36 + data_size).reinterpret_as_uint())
  buf.write_bytes(b"WAVE")
  // fmt chunk
  buf.write_bytes(b"fmt ")
  buf.write_uint_le(16U)
  buf.write_uint16_le(1) // PCM
  buf.write_uint16_le(nch.to_uint16())
  buf.write_uint_le(sample_rate.reinterpret_as_uint())
  buf.write_uint_le((sample_rate * block_align).reinterpret_as_uint())
  buf.write_uint16_le(block_align.to_uint16())
  buf.write_uint16_le(container.to_uint16())
  // data chunk
  buf.write_bytes(b"data")
  buf.write_uint_le(data_size.reinterpret_as_uint())
  for f in 0..<frames {
    for c in 0..<nch {
      let v = channels[c][f]
      if container == 8 {
        // 8 位 WAV 无符号：以 128 为中点。bps < 8（4..7）时同样要高位对齐左移，
        // 否则样本被当成满量程 8 位，整体差 2^(8-bps) 倍。
        buf.write_byte((((v << shift) + 128) & 0xFF).to_byte())
      } else {
        let scaled = v << shift
        for i in 0..<(container / 8) {
          buf.write_byte(((scaled >> (8 * i)) & 0xFF).to_byte())
        }
      }
    }
  }
  buf.to_bytes()
}
