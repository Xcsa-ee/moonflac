// frame_wbtest.mbt
//
// 帧头判据：字段解码、CRC-8、保留码拒绝、变长帧号。

///|
test "表码帧头：块长 192 + 采样率 44100 + 16 位" {
  let info = parse_metadata(tb_flac_header(192, 44100, 1, 16, 0, false)).stream_info
  let header = tb_frame_header(192, 44100, 0, 16, 0, 0, 9)
  let br = BitReader::new(header)
  let h = parse_frame_header(br, info)
  @test.assert_eq(h.block_size, 192)
  @test.assert_eq(h.channels, 1)
  @test.assert_eq(h.bits_per_sample, 16)
  @test.assert_eq(h.channel_assignment, 0)
  @test.assert_eq(br.pos, header.length() * 8)
}

///|
test "8 位与 16 位块长扩展字段 + 采样率扩展码" {
  let info = parse_metadata(tb_flac_header(64, 44100, 1, 16, 0, false)).stream_info
  // bs_bits=8：块长 64 走 8 位扩展
  let header = tb_frame_header(64, 44100, 0, 16, 0, 8, 9)
  let h = parse_frame_header(BitReader::new(header), info)
  @test.assert_eq(h.block_size, 64)
  // 16 位扩展（块长 1000）
  let info2 = parse_metadata(tb_flac_header(1000, 44100, 1, 16, 0, false)).stream_info
  let header2 = tb_frame_header(1000, 44100, 0, 16, 0, 16, 9)
  let h2 = parse_frame_header(BitReader::new(header2), info2)
  @test.assert_eq(h2.block_size, 1000)
}

///|
test "CRC-8 损坏被拒绝" {
  let info = parse_metadata(tb_flac_header(192, 44100, 1, 16, 0, false)).stream_info
  let header = tb_frame_header(192, 44100, 0, 16, 0, 0, 9)
  let bad = []
  for i in 0..<header.length() {
    bad.push(header.unsafe_get(i).to_int())
  }
  let last = bad.length() - 1
  bad[last] = bad[last] ^ 0x55
  try {
    let _ = parse_frame_header(BitReader::new(tb_bytes(bad)), info)
    abort("应当 BadCrc")
  } catch {
    FlacError::BadCrc(kind~, ..) => @test.assert_eq(kind, "CRC-8")
    _ => abort("错误类型不对: 应为 BadCrc")
  }
}

///|
test "保留码与同步码拒绝" {
  let info = parse_metadata(tb_flac_header(192, 44100, 1, 16, 0, false)).stream_info
  // 块长码 0
  let w = TestBW::new()
  w.w(0x3FFE, 14)
  w.w(0, 1)
  w.w(0, 1)
  w.w(0, 4)
  w.w(9, 4)
  w.w(0, 4)
  w.w(4, 3)
  w.w(0, 1)
  w.w(0, 8)
  try {
    let _ = parse_frame_header(BitReader::new(w.bytes()), info)
    abort("应当 BadFrameHeader")
  } catch {
    FlacError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
  // 同步码错误
  let w2 = TestBW::new()
  w2.w(0x3FFD, 14)
  try {
    let _ = parse_frame_header(BitReader::new(w2.bytes()), info)
    abort("应当 BadFrameHeader")
  } catch {
    FlacError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "位深码 3（保留值）拒绝" {
  let info = parse_metadata(tb_flac_header(192, 44100, 1, 16, 0, false)).stream_info
  // 块长码 1（192）、采样率码 9（44100）、声道 0、位深码 3（保留）
  let w = TestBW::new()
  w.w(0x3FFE, 14)
  w.w(0, 1) // 保留位
  w.w(0, 1) // 阻塞策略
  w.w(1, 4) // 块长码 1
  w.w(9, 4) // 采样率码 9
  w.w(0, 4) // 声道分配 0（mono）
  w.w(3, 3) // 位深码 3 = 保留值
  w.w(0, 1) // 帧头末保留位
  w.w(0, 8) // 帧号 0
  try {
    let _ = parse_frame_header(BitReader::new(w.bytes()), info)
    abort("应当 BadFrameHeader")
  } catch {
    FlacError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "变长帧号：两字节 200 + 0xFF 拒绝" {
  let info = parse_metadata(tb_flac_header(192, 44100, 1, 16, 0, false)).stream_info
  let header = tb_frame_header(192, 44100, 0, 16, 200, 0, 9)
  let h = parse_frame_header(BitReader::new(header), info)
  @test.assert_eq(h.block_size, 192) // 两字节帧号解析成功、后续字段未错位
  // 0xFF 首字节非法
  let w = TestBW::new()
  w.w(0x3FFE, 14)
  w.w(0, 1)
  w.w(0, 1)
  w.w(1, 4)
  w.w(9, 4)
  w.w(0, 4)
  w.w(4, 3)
  w.w(0, 1)
  w.w(0xFF, 8)
  try {
    let _ = parse_frame_header(BitReader::new(w.bytes()), info)
    abort("应当 BadFrameHeader")
  } catch {
    FlacError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
}
