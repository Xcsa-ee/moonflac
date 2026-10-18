// flac.mbt
//
// 顶层解码编排：元数据 → 帧定位（同步扫描 + 帧头校验）→ 子帧解码 →
// 声道去相关 → 输出。声道去相关公式（left/right/side、mid/side 的
// `mid' = (mid<<1)|(side&1)` 还原）经 ffmpeg 手造帧与真实文件双向验证；
// side 声道位宽恒为 bps+1（bps=32 时 33 位，故子帧域用 Int64）。

///|
/// 整文件解码结果（planar：每声道一个样本数组，样本为 bps 位宽的有符号值）。
pub struct FlacFile {
  /// 流的 STREAMINFO 等元数据。
  info : StreamInfo
  /// 每声道样本（声道数 = `info.channels`）。
  channels : Array[Array[Int32]]
}

///|
/// 尝试在读取器当前位置解析帧头：任何帧头级失败（同步码、保留位、
/// 变长帧号、CRC-8、截断）都折叠为 None，交给上层决定是否继续扫描；
/// 帧头之后的子帧/CRC-16 错误则直接上抛，不静默跳过。
fn try_parse_header(br : BitReader, info : StreamInfo) -> FrameHeader? {
  Some(parse_frame_header(br, info)) catch {
    _ => None
  }
}

///|
/// 解码帧体：各声道子帧 + 零填充到字节边界 + CRC-16 校验。
/// 成功后读取器停在下一帧起点（字节边界）。
fn decode_frame_body(
  br : BitReader,
  h : FrameHeader,
  temp : Array[Array[Int64]],
) -> Unit raise FlacError {
  let side_idx = if h.channel_assignment == 8 || h.channel_assignment == 10 {
    1
  } else if h.channel_assignment == 9 {
    0
  } else {
    -1
  }
  for c in 0..<h.channels {
    let cbps = if c == side_idx {
      h.bits_per_sample + 1
    } else {
      h.bits_per_sample
    }
    decode_subframe(br, temp[c], h.block_size, cbps)
  }
  // 子帧区零填充到字节边界（帧 CRC-16 之前）
  if !br.is_aligned() {
    let pad = 8 - (br.pos & 7)
    for _ in 0..<pad {
      if br.read_bit() != 0 {
        raise BadSubframe(reason="帧尾填充位非零")
      }
    }
  }
  br.check()
  let crc_pos = br.pos >> 3
  let expect = br.read_bits64(16).to_int()
  br.check()
  let actual = crc16_range(br.data, h.start_byte, crc_pos)
  if expect != actual {
    raise BadCrc(kind="CRC-16", expected=actual, actual=expect)
  }
}

///|
/// 解码整条 FLAC 流。
///
/// - 帧头级失败会向后扫描同步码尝试重同步（容忍尾部附带的标签等杂字节）；
/// - 子帧或 CRC-16 失败直接报错，不跳帧，保证错误可见；
/// - `STREAMINFO.total_samples` 非 0 时以此为准截断输出，且帧数不足会报
///   Truncated 而不是静默少样本。
pub fn decode(data : Bytes) -> FlacFile raise FlacError {
  let meta = parse_metadata(data)
  let info = meta.stream_info
  let br = BitReader::new(data)
  br.seek(meta.frame_offset * 8)
  let out : Array[Array[Int32]] = []
  for _ in 0..<info.channels {
    out.push([])
  }
  let total = info.total_samples
  let mut decoded : Int64 = 0
  let mut eof = false
  while !eof {
    if total > 0 && decoded >= total {
      break
    }
    // —— 定位下一个可解析的帧头 ——
    let mut header : FrameHeader? = None
    let mut scan_done = false
    while header is None && !scan_done {
      let cur = br.pos >> 3
      br.truncated = false
      header = try_parse_header(br, info)
      if header is None {
        let next = scan_sync(data, cur + 1)
        if next < 0 {
          scan_done = true
        } else {
          br.seek(next * 8)
        }
      }
    }
    if header is None {
      // 扫描到数据尽头：总样本数已知且不足时报错，未知时视为正常 EOF
      eof = true
    } else {
      match header {
        None => eof = true
        Some(h) => {
          let temp : Array[Array[Int64]] = []
          for _ in 0..<h.channels {
            temp.push(Array::make(h.block_size, 0L))
          }
          decode_frame_body(br, h, temp)
          // total_samples 已知时截断到总长
          let take64 = if total > 0 &&
            decoded + Int64::from_int(h.block_size) > total {
            total - decoded
          } else {
            Int64::from_int(h.block_size)
          }
          let take = take64.to_int()
          let assign = h.channel_assignment
          if assign <= 7 {
            for c in 0..<h.channels {
              let t = temp[c]
              for i in 0..<take {
                out[c].push(t[i].to_int())
              }
            }
          } else if assign == 8 {
            // left / side
            for i in 0..<take {
              let l = temp[0][i]
              out[0].push(l.to_int())
              out[1].push((l - temp[1][i]).to_int())
            }
          } else if assign == 9 {
            // side / right
            for i in 0..<take {
              let r = temp[1][i]
              out[0].push((temp[0][i] + r).to_int())
              out[1].push(r.to_int())
            }
          } else {
            // mid / side：mid 丢过 LSB，用 side 的最低位补回
            for i in 0..<take {
              let side = temp[1][i]
              let mid2 = (temp[0][i] << 1) | (side & 1L)
              out[0].push(((mid2 + side) >> 1).to_int())
              out[1].push(((mid2 - side) >> 1).to_int())
            }
          }
          decoded += take64
        }
      }
    }
  }
  if total > 0 && decoded < total {
    raise Truncated(
      offset=data.length(),
      need=(total - decoded).to_int(),
      actual=decoded.to_int(),
    )
  }
  { info, channels: out, }
}
