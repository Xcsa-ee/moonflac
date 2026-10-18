// crc_wbtest.mbt
//
// CRC-8 / CRC-16 判据。期望值由 Python 同多项式实现独立计算（差分来源），
// 与真实 FLAC 帧上 ffmpeg 的校验行为一致。

///|
test "crc8 已知向量" {
  @test.assert_eq(crc8_range(b"xxxx", 0, 0), 0)
  @test.assert_eq(crc8_range(b"Axxx", 0, 1), 0xC0) // 'A' = 0x41
  @test.assert_eq(crc8_range(b"123456789xxx", 0, 9), 0xF4)
}

///|
test "crc16 已知向量" {
  @test.assert_eq(crc16_range(b"xxxx", 0, 0), 0)
  @test.assert_eq(crc16_range(b"Axxx", 0, 1), 0x186)
  @test.assert_eq(crc16_range(b"123456789xxx", 0, 9), 0xFEE8)
  // 区间截取只算 [start, end)
  @test.assert_eq(crc16_range(b"xx123456789xx", 2, 11), 0xFEE8)
}

///|
test "end 越界截到数据末尾" {
  let data = b"123456789xxx" // 12 字节
  @test.assert_eq(crc8_range(data, 0, 99), crc8_range(data, 0, 12))
}
