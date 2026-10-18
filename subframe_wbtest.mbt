// subframe_wbtest.mbt
//
// 子帧判据：四类子帧、wasted bits、rice 转义、保留类型拒绝。

///|
test "CONSTANT / VERBATIM 子帧" {
  let xs = tb_decode_subframe(tb_sub_constant(-12345, 16), 64, 16)
  for i in 0..<64 {
    @test.assert_eq(xs[i], -12345L)
  }
  let samples = [1, -2, 300, -32768, 32767, 0]
  let xs2 = tb_decode_subframe(tb_sub_verbatim(samples, 16), 6, 16)
  for i in 0..<6 {
    @test.assert_eq(xs2[i], Int64::from_int(samples[i]))
  }
}

///|
test "FIXED 阶 0..4 + Rice 参数" {
  let signals : Array[Array[Int32]] = [
    [100, -200, 300, -400, 500, -600, 700, -800],
    [100, 105, 112, 121, 132, 145, 160, 177],
    [0, 1, 4, 9, 16, 25, 36, 49],
    [10, 30, 60, 100, 150, 210, 280, 360],
    [5, 17, 51, 155, 467, 1403, 4211, 12635],
  ]
  for order in 0..<5 {
    let sig = signals[order]
    for param in [0, 4, 8, 14] {
      let xs = tb_decode_subframe(tb_sub_fixed(sig, 16, order, param, 0), 8, 16)
      for i in 0..<8 {
        @test.assert_eq(xs[i], Int64::from_int(sig[i]))
      }
    }
  }
}

///|
test "rice 转义：原码 12 位" {
  let sig = [1000, 1100, 900, 1300, 800, 1400, 700, 1500] // 残差均在 12 位内
  let xs = tb_decode_subframe(tb_sub_fixed(sig, 16, 1, 15, 12), 8, 16)
  for i in 0..<8 {
    @test.assert_eq(xs[i], Int64::from_int(sig[i]))
  }
}

///|
test "wasted bits：k=1/2/3 × constant/verbatim" {
  for k in 1..<4 {
    let v = 24000 - 24000 % (1 << k)
    let xs = tb_decode_subframe(tb_sub_constant_wasted(v, 16, k), 16, 16)
    @test.assert_eq(xs[0], Int64::from_int(v))
    @test.assert_eq(xs[15], Int64::from_int(v))
  }
  // verbatim + wasted：整段左移还原
  let w = TestBW::new()
  w.w(0, 1)
  w.w(1, 6) // VERBATIM
  w.w(1, 1) // wasted flag
  w.w(1, 1) // k-1 = 0 个 0：直接终止 1 -> k=1, eff=15
  for _ in 0..<8 {
    w.w(12345, 15) // eff=15 位的 12345 -> <<1 = 24690
  }
  let xs = tb_decode_subframe(w.bytes(), 8, 16)
  @test.assert_eq(xs[0], 24690L)
}

///|
test "保留子帧类型拒绝" {
  // 类型 3：保留
  let w = TestBW::new()
  w.w(0, 1)
  w.w(3, 6)
  w.w(0, 1)
  try {
    let _ = tb_decode_subframe(w.bytes(), 8, 16)
    abort("应当 BadSubframe")
  } catch {
    FlacError::BadSubframe(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "LPC 子帧：精度 5 系数现场重建" {
  let sig = [1000, 990, 979, 967, 954, 940, 925, 909]
  let xs = tb_decode_subframe(tb_sub_lpc(sig, 16, 2, 5, [2, -1], 1), 8, 16)
  for i in 0..<8 {
    @test.assert_eq(xs[i], Int64::from_int(sig[i]))
  }
}
