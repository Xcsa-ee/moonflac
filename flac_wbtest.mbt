// flac_wbtest.mbt
//
// 端到端判据：整流解码（含多帧、声道去相关）、负例、WAV 序列化。

///|
test "多帧常数流端到端" {
  let frames = []
  for i in 0..<4 {
    let hdr = tb_frame_header(64, 44100, 0, 16, i, 0, 9)
    frames.push(tb_pack_frame(hdr, tb_sub_constant(i - 2, 16)))
  }
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 256L, false), frames)
  let file = decode(data)
  @test.assert_eq(file.channels.length(), 1)
  @test.assert_eq(file.channels[0].length(), 256)
  @test.assert_eq(file.channels[0][0], -2)
  @test.assert_eq(file.channels[0][64], -1)
  @test.assert_eq(file.channels[0][255], 1)
}

///|
test "mid/side 去相关还原" {
  // 两帧 8 样本，mid/side (assignment=10)，用可精确还原的值
  let left = [
    1000, -2000, 3000, -30000, 32767, -32768, 0, 7, 100, -100, 5000, -5000, 12345,
    -12345, 22222, -22222,
  ]
  let right = [
    500, -1500, 2500, 29999, -32768, 32767, 1, 6, -100, 100, -5000, 5000, -12345,
    12345, -22222, 22222,
  ]
  let mids = []
  let sides = []
  for i in 0..<16 {
    mids.push((left[i] + right[i]) >> 1)
    sides.push(left[i] - right[i])
  }
  let w = TestBW::new()
  let s1 = tb_sub_verbatim(mids, 16)
  let s2 = tb_sub_verbatim(sides, 17)
  for i in 0..<s1.length() {
    w.w(s1.unsafe_get(i).to_int(), 8)
  }
  for i in 0..<s2.length() {
    w.w(s2.unsafe_get(i).to_int(), 8)
  }
  let hdr = tb_frame_header(16, 44100, 10, 16, 0, 0, 9)
  let data = tb_flac(tb_flac_header(16, 44100, 2, 16, 16L, false), [
    tb_pack_frame(hdr, w.bytes()),
  ])
  let file = decode(data)
  for i in 0..<16 {
    @test.assert_eq(file.channels[0][i], left[i])
    @test.assert_eq(file.channels[1][i], right[i])
  }
}

///|
test "total_samples 截断且不足报错" {
  // 流声明 100 样本但实际 128 -> 截到 100
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let hdr2 = tb_frame_header(64, 44100, 0, 16, 1, 0, 9)
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 100L, false), [
    tb_pack_frame(hdr, tb_sub_constant(7, 16)),
    tb_pack_frame(hdr2, tb_sub_constant(7, 16)),
  ])
  let file = decode(data)
  @test.assert_eq(file.channels[0].length(), 100)
  // 流声明 200 但只给了 128 -> Truncated
  let data2 = tb_flac(tb_flac_header(64, 44100, 1, 16, 200L, false), [
    tb_pack_frame(hdr, tb_sub_constant(7, 16)),
    tb_pack_frame(hdr2, tb_sub_constant(7, 16)),
  ])
  try {
    let _ = decode(data2)
    abort("应当 Truncated")
  } catch {
    FlacError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "尾部杂字节容忍（重同步）" {
  // 帧后追加 128 字节标签样杂数据：帧数已满不受影响
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let frames = [tb_pack_frame(hdr, tb_sub_constant(3, 16))]
  let good = tb_flac(tb_flac_header(64, 44100, 1, 16, 64L, false), frames)
  let w = TestBW::new()
  for i in 0..<good.length() {
    w.w(good.unsafe_get(i).to_int(), 8)
  }
  for _ in 0..<128 {
    w.w(0xAA, 8)
  }
  let file = decode(w.bytes())
  @test.assert_eq(file.channels[0].length(), 64)
}

///|
test "负例：魔数 / CRC-16 损坏" {
  try {
    let _ = decode(tb_bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0]))
    abort("应当 NotFlac")
  } catch {
    FlacError::NotFlac => ()
    _ => abort("错误类型不对")
  }
  // CRC-16 损坏：翻转帧数据中部字节
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let frame = tb_pack_frame(hdr, tb_sub_constant(5, 16))
  let bad = []
  for i in 0..<frame.length() {
    bad.push(frame.unsafe_get(i).to_int())
  }
  // 翻转最后一字节 = CRC-16 低字节：结构完整可解析，必然校验失败
  let last = bad.length() - 1
  bad[last] = bad[last] ^ 0xFF
  let w = TestBW::new()
  let head = tb_flac_header(64, 44100, 1, 16, 64L, false)
  for i in 0..<head.length() {
    w.w(head.unsafe_get(i).to_int(), 8)
  }
  for b in bad {
    w.w(b, 8)
  }
  try {
    let _ = decode(w.bytes())
    abort("应当报错")
  } catch {
    FlacError::BadCrc(kind~, ..) => @test.assert_eq(kind, "CRC-16")
    _ => abort("错误类型不对: 应为 CRC-16")
  }
}

///|
test "WAV：头部字段与样本字节" {
  let wav = wav_encode([[1, -2, 32767, -32768]], 16, 8000)
  // RIFF/WAVE
  @test.assert_eq(wav.unsafe_get(0).to_int(), 0x52)
  @test.assert_eq(wav.unsafe_get(8).to_int(), 0x57)
  // fmt: 采样率在偏移 24..28
  let rate = wav.unsafe_get(24).to_int() |
    (wav.unsafe_get(25).to_int() << 8) |
    (wav.unsafe_get(26).to_int() << 16) |
    (wav.unsafe_get(27).to_int() << 24)
  @test.assert_eq(rate, 8000)
  // 位深在偏移 34..36
  @test.assert_eq(wav.unsafe_get(34).to_int(), 16)
  // data 偏移 44 起：1 -> 01 00；-2 -> FE FF
  @test.assert_eq(wav.unsafe_get(44).to_int(), 0x01)
  @test.assert_eq(wav.unsafe_get(45).to_int(), 0x00)
  @test.assert_eq(wav.unsafe_get(46).to_int(), 0xFE)
  @test.assert_eq(wav.unsafe_get(47).to_int(), 0xFF)
  // 8 位：无符号偏置 128；样本 0 -> 128
  let wav8 = wav_encode([[0, 1, -1]], 8, 8000)
  @test.assert_eq(wav8.unsafe_get(44).to_int(), 128)
  @test.assert_eq(wav8.unsafe_get(45).to_int(), 129)
  @test.assert_eq(wav8.unsafe_get(46).to_int(), 127)
  // 24 位容器 3 字节小端
  let wav24 = wav_encode([[0x123456]], 24, 44100)
  @test.assert_eq(wav24.unsafe_get(34).to_int(), 24)
  @test.assert_eq(wav24.unsafe_get(44).to_int(), 0x56)
  @test.assert_eq(wav24.unsafe_get(45).to_int(), 0x34)
  @test.assert_eq(wav24.unsafe_get(46).to_int(), 0x12)
}
