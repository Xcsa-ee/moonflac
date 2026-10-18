// metadata_wbtest.mbt
//
// 元数据解析判据：STREAMINFO 全字段、块链遍历、各类非法输入。

///|
test "最小流解析：STREAMINFO 字段" {
  let data = tb_flac_header(4608, 44100, 2, 24, 123456789L, false)
  let meta = parse_metadata(data)
  @test.assert_eq(meta.stream_info.min_block_size, 4608)
  @test.assert_eq(meta.stream_info.max_block_size, 4608)
  @test.assert_eq(meta.stream_info.sample_rate, 44100)
  @test.assert_eq(meta.stream_info.channels, 2)
  @test.assert_eq(meta.stream_info.bits_per_sample, 24)
  @test.assert_eq(meta.stream_info.total_samples, 123456789L)
  @test.assert_eq(meta.blocks.length(), 0)
  @test.assert_eq(meta.frame_offset, 4 + 4 + 34)
}

///|
test "带 PADDING 块：块链与帧偏移" {
  let data = tb_flac_header(4608, 48000, 1, 16, 1000L, true)
  let meta = parse_metadata(data)
  @test.assert_eq(meta.blocks.length(), 1)
  @test.assert_eq(meta.blocks[0].block_type, 1) // PADDING
  @test.assert_eq(meta.blocks[0].length, 3)
  // 帧偏移 = 魔数4 + STREAMINFO块头4+34 + PADDING块头4+3
  @test.assert_eq(meta.frame_offset, 4 + 38 + 7)
}

///|
test "非法输入全部落到错误" {
  // 魔数错误
  try {
    let _ = parse_metadata(tb_bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0]))
    abort("应当 NotFlac")
  } catch {
    FlacError::NotFlac => ()
    _ => abort("错误类型不对: 应为 NotFlac")
  }
  // 截断（不足 4 字节）
  try {
    let _ = parse_metadata(tb_bytes([0x66, 0x4C]))
    abort("应当 Truncated")
  } catch {
    FlacError::Truncated(..) => ()
    _ => abort("错误类型不对: 应为 Truncated")
  }
  // 保留块类型 7
  let w = TestBW::new()
  w.w(0x66, 8)
  w.w(0x4C, 8)
  w.w(0x61, 8)
  w.w(0x43, 8)
  w.w(1, 1)
  w.w(7, 7)
  w.w(0, 24) // last=1, type=7
  try {
    let _ = parse_metadata(w.bytes())
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对: 应为 BadMetadata")
  }
}

///|
test "STREAMINFO 数值非法校验" {
  // 位深 = 3 -> 非法（合法 4..32）
  let data = tb_flac_header(4608, 44100, 1, 3, 0, false)
  try {
    let _ = parse_metadata(data)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对: 应为 BadMetadata")
  }
  // 采样率 0 -> 非法
  let data2 = tb_flac_header(4608, 0, 1, 16, 0, false)
  try {
    let _ = parse_metadata(data2)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对: 应为 BadMetadata")
  }
}
