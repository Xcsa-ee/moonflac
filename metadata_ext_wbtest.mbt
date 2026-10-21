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

///|
/// 写 128 字节 ASCII（不足右补 0x00）。
fn tb_ascii128(w : TestBW, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  for i in 0..<128 {
    let b = if i < bytes.length() { bytes.unsafe_get(i).to_int() } else { 0 }
    w.w(b, 8)
  }
}

///|
/// 写 12 字节 ISRC（不足右补 0x00）。
fn tb_ascii12(w : TestBW, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  for i in 0..<12 {
    let b = if i < bytes.length() { bytes.unsafe_get(i).to_int() } else { 0 }
    w.w(b, 8)
  }
}

///|
/// 合法 CUESHEET 载荷：CD-DA，1 个普通轨道（2 个索引点）+ 1 个 lead-out。
fn tb_cuesheet_payload() -> Bytes {
  let w = TestBW::new()
  tb_ascii128(w, "1234567890123")
  tb_be64(w, 88200L) // lead-in
  w.w(1, 1) // is_cd
  w.w(0, 7) // 7 位保留
  for _ in 0..<258 {
    w.w(0, 8) // 258 字节保留
  }
  w.w(2, 8) // 轨道数
  // —— 轨道 1：普通音频，2 个索引点 ——
  tb_be64(w, 88200L) // 轨道偏移
  w.w(1, 8) // 轨道号
  tb_ascii12(w, "ABC123456789")
  w.w(0, 1) // 音频
  w.w(0, 1) // 无预加重
  w.w(0, 6) // 6 位保留
  for _ in 0..<13 {
    w.w(0, 8) // 13 字节保留
  }
  w.w(2, 8) // 索引点数
  // 索引 0
  tb_be64(w, 0L)
  w.w(1, 8)
  for _ in 0..<3 {
    w.w(0, 8) // 3 字节保留
  }
  // 索引 1
  tb_be64(w, 588L)
  w.w(2, 8)
  for _ in 0..<3 {
    w.w(0, 8)
  }
  // —— 轨道 2：lead-out，无索引点 ——
  tb_be64(w, 441000L)
  w.w(170, 8)
  tb_ascii12(w, "")
  w.w(0, 1)
  w.w(0, 1)
  w.w(0, 6)
  for _ in 0..<13 {
    w.w(0, 8)
  }
  w.w(0, 8) // 索引点数
  w.bytes()
}

///|
test "CUESHEET：CD-DA 全字段解析" {
  let payload = tb_cuesheet_payload()
  let block = { block_type: 5, offset: 0, length: payload.length(), }
  let cs = read_cuesheet(payload, block)
  @test.assert_eq(cs.media_catalog_number, "1234567890123")
  @test.assert_eq(cs.lead_in_samples, 88200L)
  @test.assert_eq(cs.is_cd, true)
  @test.assert_eq(cs.tracks.length(), 2)
  // 轨道 1
  @test.assert_eq(cs.tracks[0].offset, 88200L)
  @test.assert_eq(cs.tracks[0].track_number, 1)
  @test.assert_eq(cs.tracks[0].isrc, "ABC123456789")
  @test.assert_eq(cs.tracks[0].is_non_audio, false)
  @test.assert_eq(cs.tracks[0].pre_emphasis, false)
  @test.assert_eq(cs.tracks[0].indexes.length(), 2)
  @test.assert_eq(cs.tracks[0].indexes[0].offset, 0L)
  @test.assert_eq(cs.tracks[0].indexes[0].index_number, 1)
  @test.assert_eq(cs.tracks[0].indexes[1].offset, 588L)
  @test.assert_eq(cs.tracks[0].indexes[1].index_number, 2)
  // lead-out 轨道
  @test.assert_eq(cs.tracks[1].offset, 441000L)
  @test.assert_eq(cs.tracks[1].track_number, 170)
  @test.assert_eq(cs.tracks[1].isrc, "")
  @test.assert_eq(cs.tracks[1].indexes.length(), 0)
}

///|
test "CUESHEET：超过 64 字节的媒体目录号（定长 128 的判别边界）" {
  // 13 字节目录号补零到 128 后，取 64 或 128 字节结果相同，无法区分；
  // 这里用 100 字符目录号——若字段宽度写成 64 会被截断成半截。
  let mut catalog = ""
  for _ in 0..<100 {
    catalog = catalog + "C"
  }
  let w = TestBW::new()
  tb_ascii128(w, catalog)
  tb_be64(w, 0L)
  w.w(0, 1)
  w.w(0, 7)
  for _ in 0..<258 {
    w.w(0, 8)
  }
  w.w(1, 8) // 1 个轨道（lead-out）
  tb_be64(w, 0L)
  w.w(255, 8)
  tb_ascii12(w, "")
  w.w(0, 1)
  w.w(0, 1)
  w.w(0, 6)
  for _ in 0..<13 {
    w.w(0, 8)
  }
  w.w(0, 8)
  let payload = w.bytes()
  let block = { block_type: 5, offset: 0, length: payload.length(), }
  let cs = read_cuesheet(payload, block)
  @test.assert_eq(cs.media_catalog_number, catalog)
  @test.assert_eq(cs.media_catalog_number.length(), 100)
}

///|
test "CUESHEET：保留位非零 / 轨道数 0 / 截断" {
  // 258 字节保留区被写脏
  let w = TestBW::new()
  tb_ascii128(w, "")
  tb_be64(w, 0L)
  w.w(0, 1)
  w.w(0, 7)
  for i in 0..<258 {
    w.w(if i == 100 { 0xFF } else { 0 }, 8)
  }
  w.w(1, 8)
  let p = w.bytes()
  let b = { block_type: 5, offset: 0, length: p.length(), }
  try {
    let _ = read_cuesheet(p, b)
    abort("保留位非零应 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
  // 轨道数 0
  let w2 = TestBW::new()
  tb_ascii128(w2, "")
  tb_be64(w2, 0L)
  w2.w(0, 1)
  w2.w(0, 7)
  for _ in 0..<258 {
    w2.w(0, 8)
  }
  w2.w(0, 8) // track_count = 0
  let p2 = w2.bytes()
  let b2 = { block_type: 5, offset: 0, length: p2.length(), }
  try {
    let _ = read_cuesheet(p2, b2)
    abort("轨道数 0 应 BadMetadata")
  } catch {
    FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
  // 截断：轨道头不完整
  let payload = tb_cuesheet_payload()
  let b3 = { block_type: 5, offset: 0, length: payload.length() - 10, }
  try {
    let _ = read_cuesheet(payload, b3)
    abort("截断应报错")
  } catch {
    FlacError::Truncated(..) | FlacError::BadMetadata(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "CUESHEET：xiph 官方测试文件真实载荷（input-SCPAP.flac，540 字节）" {
  // 载荷提取自 xiph/flac 仓库 test/flac-to-flac-metadata-test-files/
  // input-SCPAP.flac 的 CUESHEET 块；期望值由独立 Python 解析得出。
  let payload = tb_bytes([
    49, 50, 51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 51, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 1, 88, 136, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 76, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    11, 124, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 22, 248,
    170, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0,
  ])
  let block = { block_type: 5, offset: 0, length: payload.length(), }
  let cs = read_cuesheet(payload, block)
  @test.assert_eq(cs.media_catalog_number, "1234567890123")
  @test.assert_eq(cs.lead_in_samples, 88200L)
  @test.assert_eq(cs.is_cd, true)
  @test.assert_eq(cs.tracks.length(), 3)
  @test.assert_eq(cs.tracks[0].track_number, 1)
  @test.assert_eq(cs.tracks[0].offset, 0L)
  @test.assert_eq(cs.tracks[0].is_non_audio, false)
  @test.assert_eq(cs.tracks[0].pre_emphasis, false)
  @test.assert_eq(cs.tracks[0].indexes.length(), 2)
  @test.assert_eq(cs.tracks[0].indexes[1].offset, 588L)
  @test.assert_eq(cs.tracks[0].indexes[1].index_number, 2)
  @test.assert_eq(cs.tracks[1].track_number, 2)
  @test.assert_eq(cs.tracks[1].offset, 2940L)
  @test.assert_eq(cs.tracks[1].indexes.length(), 1)
  @test.assert_eq(cs.tracks[2].track_number, 170)
  @test.assert_eq(cs.tracks[2].offset, 5880L)
  @test.assert_eq(cs.tracks[2].indexes.length(), 0)
}
