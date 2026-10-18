// subframe.mbt
//
// 子帧解析：子帧头（1 位零填充 + 6 位类型 + wasted bits 标志）与四类子帧
// （CONSTANT / VERBATIM / FIXED / LPC）。类型位图、wasted bits 的
// 「(k-1) 个 0 + 终止 1」计数约定均经 ffmpeg 双向验证。
// wasted 语义：按 eff = bps - k 位宽解码/重建，最后整体左移 k 还原。

///|
/// 解码一个子帧，把 `block_size` 个样本写入 `xs`（Int64 中间域：
/// side 声道在 bps=32 时宽 33 位，且残差重建可能瞬时超宽）。
fn decode_subframe(
  br : BitReader,
  xs : Array[Int64],
  block_size : Int32,
  bps : Int32,
) -> Unit raise FlacError {
  if br.read_bit() != 0 {
    raise BadSubframe(reason="子帧首保留位非零")
  }
  let subframe_type = br.read_bits64(6).to_int()
  br.check()
  // wasted bits：unary 计 (k-1) 个 0，终止 1；k = 零个数 + 1
  let mut k = 0
  if br.read_bit() != 0 {
    while br.read_bit() == 0 {
      k += 1
      if br.truncated {
        break
      }
    }
    k += 1
  }
  if k > bps {
    raise BadSubframe(reason="wasted 位数超过子帧位宽")
  }
  let eff = bps - k
  if subframe_type == 0 {
    // CONSTANT：一个样本值填满整帧
    let v = br.read_sample64(eff)
    for i in 0..<block_size {
      xs[i] = v
    }
  } else if subframe_type == 1 {
    // VERBATIM：逐样本原样存储
    for i in 0..<block_size {
      xs[i] = br.read_sample64(eff)
    }
  } else if subframe_type >= 8 && subframe_type <= 12 {
    // FIXED，阶 = 类型码 - 8
    let order = subframe_type - 8
    if order > block_size {
      raise BadSubframe(reason="FIXED 阶超过块长")
    }
    for i in 0..<order {
      xs[i] = br.read_sample64(eff)
    }
    decode_residuals(br, xs, block_size, order)
    reconstruct_fixed(xs, block_size, order)
  } else if subframe_type >= 32 {
    // LPC，阶 = 类型码低 5 位 + 1（1..32）
    let order = (subframe_type & 31) + 1
    if order > block_size {
      raise BadSubframe(reason="LPC 阶超过块长")
    }
    for i in 0..<order {
      xs[i] = br.read_sample64(eff)
    }
    let precision_field = br.read_bits64(4).to_int()
    if precision_field == 15 {
      // ffmpeg 对该值直接报 invalid coeff precision；其语义未在本环境验证，
      // 不发布猜测实现（经验教训 L13）。
      raise Unsupported(what="LPC 系数精度字段 15")
    }
    let precision = precision_field + 1
    let shift = br.read_bits64(5).to_int()
    let coeffs = []
    for _ in 0..<order {
      coeffs.push(br.read_sample64(precision))
    }
    decode_residuals(br, xs, block_size, order)
    reconstruct_lpc(xs, block_size, order, coeffs, shift)
  } else {
    raise BadSubframe(reason="子帧类型为保留值")
  }
  br.check()
  if k > 0 {
    for i in 0..<block_size {
      xs[i] = xs[i] << k
    }
  }
}
