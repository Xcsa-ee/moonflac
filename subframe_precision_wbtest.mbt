// subframe_precision_wbtest.mbt
//
// RFC 9639 Table 22 规定 LPC 系数精度字段为 (精度位数 - 1)，
// 且 "0b1111 is forbidden"：字段 15 对应 16-bit 精度，属非法码流，
// 必须报 BadSubframe（而非把合法情况当成未实现）。
// 合法范围是字段 0..14 = 精度 1..15 bit。

///|
test "LPC 精度字段 0b1111 按规范拒绝（非法值，非未实现）" {
  let w = TestBW::new()
  w.w(0, 1) // 子帧头：无 wasted bits
  w.w(0b100000, 6) // 类型 0b100000：LPC，order = 0 + 1 = 1
  w.w(0, 1) // wasted bits 标志 0
  w.w(1234, 16) // 1 个未编码 warm-up 样本
  w.w(15, 4) // 精度字段 = 0b1111（RFC 9639 禁止值）
  try {
    let _ = tb_decode_subframe(w.bytes(), 8, 16)
    abort("应当 BadSubframe")
  } catch {
    FlacError::BadSubframe(..) => ()
    _ => abort("错误类型不对：规范禁止值必须归为 BadSubframe")
  }
}

///|
test "LPC 精度字段 0..14（精度 1..15 bit）全部可解码" {
  // 逐档验证合法精度：字段 f → 精度 f+1，用 1 阶 LPC + 常数残差构造。
  for field in 0..<15 {
    let precision = field + 1
    let sig = [1000, 1000, 1000, 1000]
    // 1 阶 LPC，系数 [0]，shift 0 → 预测恒为 0，残差即样本本身
    let xs = tb_decode_subframe(
      tb_sub_lpc(sig, 16, 1, precision, [0], 0),
      4,
      16,
    )
    for i in 0..<4 {
      @test.assert_eq(xs[i], Int64::from_int(sig[i]))
    }
  }
}
