// stream_wbtest.mbt
//
// 流式解码判据：块迭代与整流解码等价、seek（含 SEEKTABLE 跳帧）、
// MD5 校验（通过 / 不符报错 / 非 8 倍数位深跳过）。

///|
/// 6 帧常数流：第 f 帧恒为 f + 1（64 样本/帧，共 384）。
fn tb_six_frames() -> Array[Bytes] {
  let frames : Array[Bytes] = []
  for f in 0..<6 {
    let hdr = tb_frame_header(64, 44100, 0, 16, f, 0, 9)
    frames.push(tb_pack_frame(hdr, tb_sub_constant(f + 1, 16)))
  }
  frames
}

///|
/// 与 decode() 等价性：流式逐块拼接 == 整流解码（含跨多次 next）。
test "流式与整流解码等价" {
  let header = tb_flac_header(64, 44100, 1, 16, 384L, false)
  let frames = tb_six_frames()
  let data = tb_flac(header, frames)
  let full = decode(data)
  let stream = FlacStream::new(data)
  let got : Array[Int32] = []
  let mut blocks = 0
  let mut more = true
  while more {
    match stream.next() {
      None => more = false
      Some(b) => {
        blocks += 1
        for v in b[0] {
          got.push(v)
        }
      }
    }
  }
  @test.assert_eq(blocks, 6)
  @test.assert_eq(got, full.channels[0])
}

///|
test "seek：块边界 / 块中 / 首尾边界" {
  let header = tb_flac_header(64, 44100, 1, 16, 384L, false)
  let data = tb_flac(header, tb_six_frames())
  let full = decode(data)
  // 块中（100 = 第1帧偏移36）：seek 后的全部剩余样本 == decode()[100..]
  let s1 = FlacStream::new(data)
  s1.seek(100)
  let rest : Array[Int32] = []
  let mut more = true
  while more {
    match s1.next() {
      None => more = false
      Some(b) =>
        for v in b[0] {
          rest.push(v)
        }
    }
  }
  let expect : Array[Int32] = []
  for i in 100..<384 {
    expect.push(full.channels[0][i])
  }
  @test.assert_eq(rest, expect)
  // 块边界（128）
  let s2 = FlacStream::new(data)
  s2.seek(128)
  let b = s2.next()
  match b {
    None => abort("seek(128) 后应有块")
    Some(blk) => @test.assert_eq(blk[0][0], 3) // 第2帧值 = 3
  }
  // seek(0) 回到开头
  let s3 = FlacStream::new(data)
  s3.seek(0)
  s3.seek(200) // 中途再退
  s3.seek(0)
  match s3.next() {
    None => abort("seek(0) 后应有块")
    Some(blk) => @test.assert_eq(blk[0][0], 1)
  }
  // seek 到流尾之后 -> None
  let s4 = FlacStream::new(data)
  s4.seek(384)
  match s4.next() {
    None => ()
    Some(_) => abort("流尾 seek 后应返回 None")
  }
}

///|
test "seek：SEEKTABLE 跳帧（帧头损坏时只有走点表才能成功）" {
  // 帧 0 的 CRC-16 故意破坏：从头线性解码必然报错，
  // seek 走点表直接落帧 1 才能取到样本——该用例区分"点表路径"与"线性回退"。
  let f0 = tb_pack_frame(
    tb_frame_header(64, 44100, 0, 16, 0, 0, 9),
    tb_sub_constant(11, 16),
  )
  let f0_bad : Array[Int32] = []
  for i in 0..<f0.length() {
    f0_bad.push(f0.unsafe_get(i).to_int())
  }
  let last = f0_bad.length() - 1
  f0_bad[last] = f0_bad[last] ^ 0xFF
  let f1 = tb_pack_frame(
    tb_frame_header(64, 44100, 0, 16, 1, 0, 9),
    tb_sub_constant(22, 16),
  )
  // 前缀长度：magic 4 + STREAMINFO 块 38 + SEEKTABLE 块（头 4 + 单点 18）= 64
  let prefix = 4 + 38 + 4 + 18
  // 单点：样本 64 -> 帧 1 的字节偏移
  let st2 = TestBW::new()
  tb_be64(st2, 64L)
  tb_be64(st2, Int64::from_int(prefix + f0_bad.length()))
  st2.w(64, 16)
  let header = tb_flac_blocks(64, 44100, 1, 16, 128L, zeromd5(), [
    (3, st2.bytes()),
  ]) // SEEKTABLE
  let w = TestBW::new()
  for i in 0..<header.length() {
    w.w(header.unsafe_get(i).to_int(), 8)
  }
  for b in f0_bad {
    w.w(b, 8)
  }
  for i in 0..<f1.length() {
    w.w(f1.unsafe_get(i).to_int(), 8)
  }
  let data = w.bytes()
  // 从头解码必然失败（帧 0 CRC 坏）
  try {
    let _ = decode(data)
    abort("帧 0 损坏时 decode 应报错")
  } catch {
    FlacError::BadCrc(..) | FlacError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
  // seek(70) 走点表直接落到帧 1（样本 64 起），取到 [70..128)
  let s = FlacStream::new(data)
  s.seek(70)
  let rest : Array[Int32] = []
  let mut more = true
  while more {
    match s.next() {
      None => more = false
      Some(b) =>
        for v in b[0] {
          rest.push(v)
        }
    }
  }
  @test.assert_eq(rest.length(), 58) // 128 - 70
  for v in rest {
    @test.assert_eq(v, 22) // 帧 1 的常数值
  }
}

///|
test "流式截断：total_samples 不足时下一次 next 报错" {
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let hdr2 = tb_frame_header(64, 44100, 0, 16, 1, 0, 9)
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 200L, false), [
    tb_pack_frame(hdr, tb_sub_constant(7, 16)),
    tb_pack_frame(hdr2, tb_sub_constant(7, 16)),
  ])
  let s = FlacStream::new(data)
  let _ = s.next() // 第一块 64
  let _ = s.next() // 第二块 64
  try {
    let _ = s.next() // 应报 Truncated（已解 128 < 200 且无更多帧）
    abort("应当 Truncated")
  } catch {
    FlacError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "MD5：记录且匹配 -> 通过；篡改 -> Md5Mismatch" {
  // 夹具：帧0 恒 7、帧1 恒 -3（mono 16 位 128 样本），
  // 期望 md5 = hashlib.md5(interleaved s16le).hexdigest() = 98c31aa9...
  let good_md5 = tb_bytes([
    0x98, 0xC3, 0x1A, 0xA9, 0xBB, 0xEC, 0x65, 0x6D, 0xB2, 0xBD, 0x9E, 0x89, 0x77,
    0xF2, 0xD2, 0x8D,
  ])
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let hdr2 = tb_frame_header(64, 44100, 0, 16, 1, 0, 9)
  let frames = [
    tb_pack_frame(hdr, tb_sub_constant(7, 16)),
    tb_pack_frame(hdr2, tb_sub_constant(-3, 16)),
  ]
  let data = tb_flac_blocks(64, 44100, 1, 16, 128L, good_md5, [])
  let file = decode(tb_flac(data, frames))
  @test.assert_eq(file.channels[0].length(), 128)
  @test.assert_eq(file.channels[0][0], 7)
  @test.assert_eq(file.channels[0][127], -3)
  // 篡改 md5 最后一字节
  let bad_md5 = tb_bytes([
    0x98, 0xC3, 0x1A, 0xA9, 0xBB, 0xEC, 0x65, 0x6D, 0xB2, 0xBD, 0x9E, 0x89, 0x77,
    0xF2, 0xD2, 0x00,
  ])
  let data_bad = tb_flac_blocks(64, 44100, 1, 16, 128L, bad_md5, [])
  try {
    let _ = decode(tb_flac(data_bad, frames))
    abort("应当 Md5Mismatch")
  } catch {
    FlacError::Md5Mismatch(expected~, actual~) => {
      @test.assert_eq(expected.length(), 32)
      @test.assert_eq(actual.length(), 32)
      // 流里存的是被篡改的 md5（结尾 200），实算是 28d
      @test.assert_eq(expected.has_suffix("200"), true)
      @test.assert_eq(actual.has_suffix("28d"), true)
    }
    _ => abort("错误类型不对")
  }
}

///|
test "MD5：12 位常数值流，RFC 规则 MD5 匹配通过" {
  // RFC 9639 §8.4：12 位样本符号扩展到 16 位（2 字节）小端存储。
  // 64 个恒 100 样本的期望 MD5 由独立 Python 实现的 RFC 规则算出。
  let good_md5 = tb_bytes([
    0x88, 0x97, 0x05, 0xF3, 0x32, 0x4B, 0xFE, 0xC9, 0x3F, 0x54, 0xB3, 0x1E, 0x5D,
    0x5C, 0xB1, 0x9A,
  ])
  let hdr = tb_frame_header(64, 44100, 0, 12, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 12, 64L, good_md5, [])
  let file = decode(
    tb_flac(data, [tb_pack_frame(hdr, tb_sub_constant(100, 12))]),
  )
  @test.assert_eq(file.channels[0].length(), 64)
  @test.assert_eq(file.channels[0][0], 100)
}

///|
test "MD5：12 位变值流（含负值，验证符号扩展）匹配通过" {
  // 16 样本模式重复 4 次 = 64 样本，覆盖 -2048..2047 全范围含负数。
  let good_md5 = tb_bytes([
    0x41, 0x10, 0x7D, 0x3C, 0x38, 0x9C, 0xB9, 0x6B, 0x4A, 0x84, 0x68, 0xB4, 0x16,
    0xAD, 0xB8, 0x16,
  ])
  let samples = [
    0, 1, -1, 2047, -2048, 100, -100, 7, -7, 1234, -1234, 500, -500, 2046, -2047,
    42,
  ]
  let all : Array[Int32] = []
  for _ in 0..<4 {
    for s in samples {
      all.push(s)
    }
  }
  let hdr = tb_frame_header(64, 44100, 0, 12, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 12, 64L, good_md5, [])
  let file = decode(
    tb_flac(data, [tb_pack_frame(hdr, tb_sub_verbatim(all, 12))]),
  )
  @test.assert_eq(file.channels[0].length(), 64)
  @test.assert_eq(file.channels[0][3], 2047)
  @test.assert_eq(file.channels[0][4], -2048)
}

///|
test "MD5：12 位错误 MD5 现在会被检出（不再跳过）" {
  let wrong_md5 = tb_bytes([
    0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF, 0xDE,
    0xAD, 0xBE, 0xEF,
  ])
  let hdr = tb_frame_header(64, 44100, 0, 12, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 12, 64L, wrong_md5, [])
  try {
    let _ = decode(
      tb_flac(data, [tb_pack_frame(hdr, tb_sub_constant(100, 12))]),
    )
    abort("12 位流错误 MD5 应当 Md5Mismatch，不应再跳过")
  } catch {
    FlacError::Md5Mismatch(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "MD5：4 位常数值流（RFC 规则外推到极小位深）匹配通过" {
  // 4 位样本符号扩展到 8 位（1 字节）小端存储。
  let good_md5 = tb_bytes([
    0xEF, 0x14, 0xD0, 0xD8, 0x6B, 0xF1, 0xA2, 0x2C, 0x31, 0x35, 0xBB, 0x69, 0x67,
    0x6C, 0x64, 0x57,
  ])
  let hdr = tb_frame_header(64, 44100, 0, 4, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 4, 64L, good_md5, [])
  let file = decode(tb_flac(data, [tb_pack_frame(hdr, tb_sub_constant(-3, 4))]))
  @test.assert_eq(file.channels[0].length(), 64)
  @test.assert_eq(file.channels[0][0], -3)
}

///|
test "MD5：4 位变值流（含负值）匹配通过" {
  let good_md5 = tb_bytes([
    0xBB, 0x78, 0x6A, 0xE5, 0x5C, 0x2B, 0x6C, 0x8B, 0xF3, 0x0E, 0x01, 0x27, 0x90,
    0x27, 0xBB, 0x9C,
  ])
  let pattern = [0, 1, -1, 7, -8, 3, -3, 5]
  let all : Array[Int32] = []
  for _ in 0..<8 {
    for s in pattern {
      all.push(s)
    }
  }
  let hdr = tb_frame_header(64, 44100, 0, 4, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 4, 64L, good_md5, [])
  let file = decode(
    tb_flac(data, [tb_pack_frame(hdr, tb_sub_verbatim(all, 4))]),
  )
  @test.assert_eq(file.channels[0].length(), 64)
  @test.assert_eq(file.channels[0][3], 7)
  @test.assert_eq(file.channels[0][4], -8)
}

///|
test "MD5：20 位常数值流匹配通过" {
  let good_md5 = tb_bytes([
    0x96, 0xA5, 0x9B, 0x55, 0x67, 0x1B, 0xA3, 0xE2, 0x1A, 0x5C, 0x72, 0x1C, 0x45,
    0x52, 0xFC, 0x68,
  ])
  let hdr = tb_frame_header(64, 44100, 0, 20, 0, 0, 9)
  let data = tb_flac_blocks(64, 44100, 1, 20, 64L, good_md5, [])
  let file = decode(
    tb_flac(data, [tb_pack_frame(hdr, tb_sub_constant(1000, 20))]),
  )
  @test.assert_eq(file.channels[0].length(), 64)
  @test.assert_eq(file.channels[0][0], 1000)
}
