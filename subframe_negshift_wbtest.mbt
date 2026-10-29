// subframe_negshift_wbtest.mbt
//
// RFC 9639 Table 22：Prediction right shift 是 s(5)，范围 -16..15。
// 字段值 >= 16 表示负数（预测左移）。构造负 shift 的 LPC 子帧验证
// 解码正确性——错误实现（按无符号右移）会得到完全不同的样本。

///|
test "LPC 预测右移 -1（左移 1 位）" {
  // order=1, 系数 [2], shift 字段 31 → 规范值 -1
  // pred(x[i]) = (2 * x[i-1]) << 1 = 4 * x[i-1]，残差全 0
  let sig = [100, 400, 1600, 6400]
  let xs = tb_decode_subframe(tb_sub_lpc(sig, 16, 1, 3, [2], 31), 4, 16)
  for i in 0..<4 {
    @test.assert_eq(xs[i], Int64::from_int(sig[i]))
  }
}

///|
test "LPC 预测右移 -16（左移 16 位）" {
  // shift 字段 16 → 规范值 -16；样本可超过位深（FLAC 允许预测溢出 bps）
  let sig = [1, 131072]
  let xs = tb_decode_subframe(tb_sub_lpc(sig, 16, 1, 3, [2], 16), 2, 16)
  for i in 0..<2 {
    @test.assert_eq(xs[i], Int64::from_int(sig[i]))
  }
}

///|
test "LPC 预测右移 15（正边界）" {
  // shift 字段 15 → 规范值 15；pred = acc >> 15
  let sig = [32767, 2, 0, 0]
  // 系数 [2], precision 3: pred(x1) = (2*32767) >> 15 = 1，残差 = 2-1 = 1
  // pred(x2) = (2*2) >> 15 = 0, 残差 0
  let xs = tb_decode_subframe(tb_sub_lpc(sig, 16, 1, 3, [2], 15), 4, 16)
  for i in 0..<4 {
    @test.assert_eq(xs[i], Int64::from_int(sig[i]))
  }
}
