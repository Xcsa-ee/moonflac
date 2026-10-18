// bitreader_wbtest.mbt
//
// MSB-first 位读取器判据：位序、符号扩展（含 32/33 位）、越界不 panic。

///|
test "MSB-first 位序与跨字节" {
  // 0xA5 = 1010 0101：依次读出 1,0,1,0,0,1,0,1
  let br = BitReader::new(tb_bytes([0xA5, 0x0F]))
  let bits = []
  for _ in 0..<8 {
    bits.push(br.read_bit())
  }
  @test.assert_eq(bits, [1, 0, 1, 0, 0, 1, 0, 1])
  // 跨字节一次读 8 位 = 0x0F
  @test.assert_eq(br.read_bits64(8).to_int(), 0x0F)
}

///|
test "read_bits64 超过 31 位" {
  let br = BitReader::new(tb_bytes([0x01, 0x02, 0x03, 0x04, 0x05]))
  @test.assert_eq(br.read_bits64(40), 0x0102030405L)
}

///|
test "符号扩展：15/32/33 位" {
  let br = BitReader::new(tb_bytes([0xFF, 0xFF]))
  @test.assert_eq(br.read_sample64(15), -1L)
  let br2 = BitReader::new(tb_bytes([0x80, 0x00, 0x00, 0x00]))
  @test.assert_eq(br2.read_sample64(32), -2147483648L)
  // 33 位（side 声道 32bps 场景）：首位 1 落在第 25 位 -> 2^25（正数）
  let br3 = BitReader::new(tb_bytes([0x01, 0x00, 0x00, 0x00, 0x00]))
  @test.assert_eq(br3.read_sample64(33), 33554432L)
  // 33 位全 1 -> 符号位参与，-1
  let br5 = BitReader::new(tb_bytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
  @test.assert_eq(br5.read_sample64(33), -1L)
  let br4 = BitReader::new(tb_bytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
  @test.assert_eq(br4.read_sample64(33), -1L)
}

///|
test "越界读取置 truncated 且不 panic" {
  let br = BitReader::new(tb_bytes([0x01])) // 8 位
  br.seek(8) // 恰好越界一个位
  @test.assert_eq(br.read_bit(), 0)
  @test.assert_eq(br.truncated, true)
  // check 抛 Truncated，之后标志复位
  try {
    br.check()
    abort("应当抛出 Truncated")
  } catch {
    FlacError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
  @test.assert_eq(br.truncated, false)
}

///|
test "seek 越界置 truncated，对齐判定" {
  let br = BitReader::new(tb_bytes([0x01, 0x02]))
  br.seek(16)
  @test.assert_eq(br.is_aligned(), true)
  br.seek(9)
  @test.assert_eq(br.is_aligned(), false)
  br.seek(99)
  @test.assert_eq(br.truncated, true)
}
