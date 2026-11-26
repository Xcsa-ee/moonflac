// residual_neg_wbtest.mbt
//
// 残差非法路径的结构化断言：RFC 9639 §9.2.7 的熵编码方法只有 0/1，
// 2/3 是保留值；分区数必须能整除块长。两者都必须报 BadResidual。

///|
test "残差熵编码方法 2/3 为保留值：报 BadResidual" {
  for entropy_method in [2, 3] {
    let w = TestBW::new()
    w.w(0, 1) // 子帧首保留位
    w.w(8, 6) // FIXED 阶 0
    w.w(0, 1) // wasted bits = 0
    w.w(entropy_method, 2) // 熵编码方法：保留值
    w.w(0, 4) // 分区阶 0
    try {
      let _ = tb_decode_subframe(w.bytes(), 8, 16)
      abort("熵编码方法应当报 BadResidual")
    } catch {
      FlacError::BadResidual(..) => ()
      _ => abort("错误类型不对")
    }
  }
}

///|
test "分区数不能整除块长：报 BadResidual" {
  // FIXED 阶 0、块长 6、分区阶 2（4 个分区）→ 6 % 4 != 0
  let w = TestBW::new()
  w.w(0, 1)
  w.w(8, 6)
  w.w(0, 1)
  w.w(0, 2) // 熵编码方法 0
  w.w(2, 4) // 分区阶 2
  try {
    let _ = tb_decode_subframe(w.bytes(), 6, 16)
    abort("分区不整除应当报 BadResidual")
  } catch {
    FlacError::BadResidual(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "每分区样本数小于预测阶：报 BadResidual" {
  // LPC 阶 2、块长 4、分区阶 2（4 个分区，每区 1 样本 < 阶 2）
  let w = TestBW::new()
  w.w(0, 1)
  w.w(0b100000 | 1, 6) // LPC 阶 2
  w.w(0, 1)
  w.w(100, 16) // warm-up[0]
  w.w(100, 16) // warm-up[1]
  w.w(3, 4) // 精度字段 3 → 精度 4
  w.w(0, 5) // shift 0
  w.w(0, 4) // 系数[0]
  w.w(0, 4) // 系数[1]
  w.w(0, 2) // 熵编码方法 0
  w.w(2, 4) // 分区阶 2 → psize = 1 < 阶 2
  try {
    let _ = tb_decode_subframe(w.bytes(), 4, 16)
    abort("每分区样本数小于阶应当报 BadResidual")
  } catch {
    FlacError::BadResidual(..) => ()
    _ => abort("错误类型不对")
  }
}
