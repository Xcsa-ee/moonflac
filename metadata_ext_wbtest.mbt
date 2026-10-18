// metadata_ext_wbtest.mbt
//
// 元数据块内容读取判据：SEEKTABLE / VORBIS_COMMENT / PICTURE / APPLICATION。

///|
/// 2 个有效定位点 + 1 个占位点（占位按规范忽略）的 SEEKTABLE 载荷。
fn tb_seektable_payload() -> Bytes {
  let w = TestBW::new()
  // 点 0: 样本 0, 字节偏移 82, 帧长 64
  tb_be64(w, 0L)
  tb_be64(w, 82L)
  w.w(64, 16)
  // 点 1: 样本 64, 字节偏移 999, 帧长 64
  tb_be64(w, 64L)
  tb_be64(w, 999L)
  w.w(64, 16)
  // 占位点: 样本号全 1（规范要求忽略）
  tb_be64(w, -1L)
  tb_be64(w, -1L)
  w.w(0xFFFF, 16)
  w.bytes()
}

///|
test "SEEKTABLE：有效点解析、占位点忽略" {
  let payload = tb_seektable_payload()
  let block = { block_type: 3, offset: 0, length: payload.length(), }
  let pts = read_seektable(payload, block)
  @test.assert_eq(pts.length(), 2)
  @test.assert_eq(pts[0].sample_position, 0L)
  @test.assert_eq(pts[0].byte_offset, 82L)
  @test.assert_eq(pts[0].frame_samples, 64)
  @test.assert_eq(pts[1].sample_position, 64L)
  @test.assert_eq(pts[1].byte_offset, 999L)
}

///|
test "SEEKTABLE：长度非 18 倍数 / 高位字节非法" {
  let payload = tb_seektable_payload()
  let bad = { block_type: 3, offset: 0, length: payload.length() - 1, }
  try {
    let _ = read_seektable(payload, bad)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
  // 非占位但样本号最高位为 1 -> 非法
  let w = TestBW::new()
  w.w(0x80, 8)
  for _ in 1..<18 {
    w.w(0, 8)
  }
  let b2 = { block_type: 3, offset: 0, length: 18, }
  try {
    let _ = read_seektable(w.bytes(), b2)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "VORBIS_COMMENT：UTF-8 值与等号切分" {
  let w = TestBW::new()
  // vendor = "Lavf61"（6 字节）
  tb_le32(w, 6)
  for b in [76, 97, 118, 102, 54, 49] {
    w.w(b, 8)
  }
  tb_le32(w, 2) // 2 条注释
  // "TITLE=测试"（UTF-8: 测试 = E6B58B E8AF95）
  tb_le32(w, 12)
  for b in [84, 73, 84, 76, 69, 61, 0xE6, 0xB5, 0x8B, 0xE8, 0xAF, 0x95] {
    w.w(b, 8)
  }
  // "ARTIST=A=B" —— 按第一个 = 切分
  tb_le32(w, 10)
  for b in [65, 82, 84, 73, 83, 84, 61, 65, 61, 66] {
    w.w(b, 8)
  }
  let payload = w.bytes()
  let block = { block_type: 4, offset: 0, length: payload.length(), }
  let vc = read_vorbis_comment(payload, block)
  @test.assert_eq(vc.vendor, "Lavf61")
  @test.assert_eq(vc.comments.length(), 2)
  @test.assert_eq(vc.comments[0].0, "TITLE")
  @test.assert_eq(vc.comments[0].1, "测试")
  @test.assert_eq(vc.comments[1].0, "ARTIST")
  @test.assert_eq(vc.comments[1].1, "A=B")
}

///|
test "VORBIS_COMMENT：条目数不符 / 缺分隔符" {
  let w = TestBW::new()
  tb_le32(w, 1)
  w.w(88, 8) // "X"
  tb_le32(w, 3) // 声称 3 条，实际 0 条
  let payload = w.bytes()
  let block = { block_type: 4, offset: 0, length: payload.length(), }
  try {
    let _ = read_vorbis_comment(payload, block)
    abort("应当报错")
  } catch {
    FlacError::Truncated(..) | FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
  // 缺 '='
  let w2 = TestBW::new()
  tb_le32(w2, 1)
  w2.w(88, 8)
  tb_le32(w2, 1) // count = 1
  tb_le32(w2, 1) // 项长度 = 1
  w2.w(89, 8) // "Y" 无 =
  let p2 = w2.bytes()
  let b2 = { block_type: 4, offset: 0, length: p2.length(), }
  try {
    let _ = read_vorbis_comment(p2, b2)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "PICTURE：全字段解析与数据边界" {
  let w = TestBW::new()
  tb_be32(w, 3) // 封面
  tb_be32(w, 9)
  for b in [105, 109, 97, 103, 101, 47, 112, 110, 103] {
    w.w(b, 8) // image/png
  }
  tb_be32(w, 6)
  for b in [0xE5, 0xB0, 0x81, 0xE9, 0x9D, 0xA2] {
    w.w(b, 8) // 封面
  }
  tb_be32(w, 2) // 宽
  tb_be32(w, 3) // 高
  tb_be32(w, 24) // 深
  tb_be32(w, 0) // 色数
  tb_be32(w, 4) // 数据长
  for b in [0x89, 0x50, 0x4E, 0x47] {
    w.w(b, 8)
  }
  let payload = w.bytes()
  let block = { block_type: 6, offset: 0, length: payload.length(), }
  let pic = read_picture(payload, block)
  @test.assert_eq(pic.picture_type, 3)
  @test.assert_eq(pic.mime, "image/png")
  @test.assert_eq(pic.description, "封面")
  @test.assert_eq(pic.width, 2)
  @test.assert_eq(pic.height, 3)
  @test.assert_eq(pic.depth, 24)
  @test.assert_eq(pic.colors, 0)
  @test.assert_eq(pic.data.length(), 4)
  @test.assert_eq(pic.data.unsafe_get(0).to_int(), 0x89)
  // 数据长超出块范围
  let w2 = TestBW::new()
  tb_be32(w2, 3)
  tb_be32(w2, 0)
  tb_be32(w2, 0)
  tb_be32(w2, 0)
  tb_be32(w2, 0)
  tb_be32(w2, 0)
  tb_be32(w2, 0) // colors
  tb_be32(w2, 1000000) // 数据长 100 万，块里没有
  let p2 = w2.bytes()
  let b2 = { block_type: 6, offset: 0, length: p2.length(), }
  try {
    let _ = read_picture(p2, b2)
    abort("应当报错")
  } catch {
    FlacError::Truncated(..) | FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "APPLICATION：标识与数据" {
  let w = TestBW::new()
  for b in [77, 79, 79, 78] {
    w.w(b, 8) // MOON
  }
  for b in [1, 2, 3] {
    w.w(b, 8)
  }
  let payload = w.bytes()
  let block = { block_type: 2, offset: 0, length: payload.length(), }
  let app = read_application(payload, block)
  @test.assert_eq(app.app_id, "MOON")
  @test.assert_eq(app.data.length(), 3)
  @test.assert_eq(app.data.unsafe_get(2).to_int(), 3)
  // 短于 4 字节 -> 非法
  let b2 = { block_type: 2, offset: 0, length: 3, }
  try {
    let _ = read_application(payload, b2)
    abort("应当 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) | FlacError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}
