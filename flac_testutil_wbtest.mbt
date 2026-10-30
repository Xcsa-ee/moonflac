// flac_testutil_wbtest.mbt
//
// 测试基座：白盒测试包内共用的位写入器与帧/子帧构造器。
// 构造器遵循的位层约定与 tools/gen_corpus.py 相同，全部经 ffmpeg 验证，
// 此处不依赖任何外部文件。

///|
/// 测试用 MSB-first 位写入器。
struct TestBW {
  buf : @buffer.Buffer
  mut acc : Int32
  mut n : Int32
}

///|
fn TestBW::new() -> TestBW {
  { buf: @buffer.Buffer(), acc: 0, n: 0, }
}

///|
fn TestBW::w(self : TestBW, value : Int32, bits : Int32) -> Unit {
  guard! bits >= 0 && bits <= 32
  if bits == 0 {
    return
  }
  guard! value >= 0 && value < 1 << bits
  self.acc = (self.acc << bits) | value
  self.n += bits
  while self.n >= 8 {
    self.n -= 8
    self.buf.write_byte(((self.acc >> self.n) & 0xFF).to_byte())
  }
}

///|
fn TestBW::w64(self : TestBW, value : Int64, bits : Int32) -> Unit {
  guard! bits >= 0 && bits <= 64
  let mut i = bits - 1
  while i >= 0 {
    self.w((((value >> i) & 1L) != 0L).to_int(), 1)
    i -= 1
  }
}

///|
fn TestBW::align(self : TestBW) -> Unit {
  if self.n != 0 {
    self.w(0, 8 - self.n)
  }
}

///|
fn TestBW::bytes(self : TestBW) -> Bytes {
  self.align()
  self.buf.to_bytes()
}

///|
/// STREAMINFO 块载荷（34 字节）；md5 为 16 字节（全零 = 未记录）。
fn tb_streaminfo(
  block_size : Int32,
  rate : Int32,
  ch : Int32,
  bps : Int32,
  total : Int64,
  md5 : Bytes,
) -> Bytes {
  let w = TestBW::new()
  w.w(block_size, 16)
  w.w(block_size, 16)
  w.w(0, 24) // min frame size 未知
  w.w(0, 24)
  w.w(rate, 20)
  w.w(ch - 1, 3)
  w.w(bps - 1, 5)
  // 36 位总样本数：高 4 位 + 两段 16 位（避开 Int 上限）
  w.w(((total >> 32) & 0xFL).to_int(), 4)
  w.w(((total >> 16) & 0xFFFFL).to_int(), 16)
  w.w((total & 0xFFFFL).to_int(), 16)
  for i in 0..<16 {
    let b = if i < md5.length() { md5.unsafe_get(i).to_int() } else { 0 }
    w.w(b, 8)
  }
  w.bytes()
}

///|
/// 带 STREAMINFO 的最小合法 FLAC 头 + 各块。
fn tb_flac_header(
  block_size : Int32,
  rate : Int32,
  ch : Int32,
  bps : Int32,
  total : Int64,
  extra_blocks : Bool,
) -> Bytes {
  let w = TestBW::new()
  w.w(0x66, 8)
  w.w(0x4C, 8)
  w.w(0x61, 8)
  w.w(0x43, 8)
  let info = tb_streaminfo(block_size, rate, ch, bps, total, zeromd5())
  // STREAMINFO 块头：last 标志视 extra_blocks
  w.w(if extra_blocks { 0 } else { 1 }, 1)
  w.w(0, 7)
  w.w(info.length(), 24)
  for i in 0..<info.length() {
    w.w(info.unsafe_get(i).to_int(), 8)
  }
  if extra_blocks {
    // 一个 PADDING 块（last=1），载荷 3 字节
    w.w(1, 1)
    w.w(1, 7)
    w.w(3, 24)
    w.w(0, 24)
  }
  w.bytes()
}

///|
/// 帧头（不含 CRC-8 时由调用方追加）。
fn tb_frame_header(
  block_size : Int32,
  _rate : Int32,
  ch_assign : Int32,
  bps : Int32,
  number : Int32,
  bs_bits : Int32,
  sr_code : Int32,
) -> Bytes {
  let w = TestBW::new()
  w.w(0b11111111111110, 14)
  w.w(0, 1)
  w.w(0, 1) // 固定块长
  // 块长码：优先表码，force 8/16 时强制扩展字段，其余自动扩展
  let table = if block_size == 192 {
    1
  } else if block_size == 576 {
    2
  } else if block_size == 1152 {
    3
  } else if block_size == 2304 {
    4
  } else if block_size == 4608 {
    5
  } else if block_size == 256 {
    8
  } else if block_size == 512 {
    9
  } else if block_size == 1024 {
    10
  } else if block_size == 2048 {
    11
  } else if block_size == 4096 {
    12
  } else if block_size == 8192 {
    13
  } else if block_size == 16384 {
    14
  } else if block_size == 32768 {
    15
  } else {
    0
  }
  let mut ext_bits = bs_bits
  if ext_bits == 0 && table == 0 {
    ext_bits = if block_size - 1 < 256 { 8 } else { 16 }
  }
  if ext_bits == 8 {
    w.w(6, 4)
  } else if ext_bits == 16 {
    w.w(7, 4)
  } else {
    w.w(table, 4)
  }
  w.w(sr_code, 4)
  w.w(ch_assign, 4)
  // 位深码：0 = 取自 STREAMINFO（非 8 倍数位深如 4/14/20 之外的
  // 其他值只能走这条）；8/12/16/20/24/32 有专属码。
  w.w(
    match bps {
      8 => 1
      12 => 2
      16 => 4
      20 => 5
      24 => 6
      32 => 7
      _ => 0
    },
    3,
  )
  w.w(0, 1)
  // 变长帧号/样本号（UTF-8 形变 1..3 字节）
  tb_utf8(w, number)
  if ext_bits == 8 || ext_bits == 16 {
    w.w(block_size - 1, ext_bits)
  }
  w.align()
  let body = w.bytes()
  // 追加 CRC-8
  let w2 = TestBW::new()
  for i in 0..<body.length() {
    w2.w(body.unsafe_get(i).to_int(), 8)
  }
  w2.w(crc8_range(body, 0, body.length()), 8)
  w2.bytes()
}

///|
/// CONST 子帧。
fn tb_sub_constant(value : Int32, bps : Int32) -> Bytes {
  let w = TestBW::new()
  w.w(0, 1)
  w.w(0, 6)
  w.w(0, 1)
  w.w(value & ((1 << bps) - 1), bps)
  w.bytes()
}

///|
/// VERBATIM 子帧。
fn tb_sub_verbatim(samples : Array[Int32], bps : Int32) -> Bytes {
  let w = TestBW::new()
  w.w(0, 1)
  w.w(1, 6)
  w.w(0, 1)
  let mask = (1 << bps) - 1
  for s in samples {
    w.w(s & mask, bps)
  }
  w.bytes()
}

///|
/// zigzag 编码（测试写入侧）。
fn tb_zigzag(v : Int64) -> Int64 {
  if v < 0L {
    -2L * v - 1L
  } else {
    2L * v
  }
}

///|
/// FIXED 子帧（单分区；param<15 走 Rice，否则转义原码）。
fn tb_sub_fixed(
  samples : Array[Int32],
  bps : Int32,
  order : Int32,
  param : Int32,
  raw_bits : Int32,
) -> Bytes {
  let w = TestBW::new()
  w.w(0, 1)
  w.w(0b001000 | order, 6)
  w.w(0, 1)
  let mask = (1 << bps) - 1
  for i in 0..<order {
    w.w(samples[i] & mask, bps)
  }
  // 残差
  let res = []
  for i in order..<samples.length() {
    let mut r = Int64::from_int(samples[i])
    if order == 1 {
      r = r - Int64::from_int(samples[i - 1])
    } else if order == 2 {
      r = r -
        2L * Int64::from_int(samples[i - 1]) +
        Int64::from_int(samples[i - 2])
    } else if order == 3 {
      r = r -
        3L * Int64::from_int(samples[i - 1]) +
        3L * Int64::from_int(samples[i - 2]) -
        Int64::from_int(samples[i - 3])
    } else if order == 4 {
      r = r -
        4L * Int64::from_int(samples[i - 1]) +
        6L * Int64::from_int(samples[i - 2]) -
        4L * Int64::from_int(samples[i - 3]) +
        Int64::from_int(samples[i - 4])
    }
    res.push(r)
  }
  w.w(0, 2) // 方法 0：Rice
  w.w(0, 4) // 分区序 0
  if param >= 15 {
    // 转义：15 + 5 位原码位宽
    w.w(15, 4)
    w.w(raw_bits, 5)
    for r in res {
      w.w64(r & ((Int64::from_int(1) << raw_bits) - 1L), raw_bits)
    }
  } else {
    w.w(param, 4)
    for r in res {
      let z = tb_zigzag(r)
      let q = (z >> param).to_int()
      for _ in 0..<q {
        w.w(0, 1) // q 个 0
      }
      w.w(1, 1) // 终止 1
      if param > 0 {
        w.w((z & ((Int64::from_int(1) << param) - 1L)).to_int(), param)
      }
    }
  }
  w.bytes()
}

///|
/// CONSTANT + wasted bits 子帧。
fn tb_sub_constant_wasted(value : Int32, bps : Int32, k : Int32) -> Bytes {
  let w = TestBW::new()
  w.w(0, 1)
  w.w(0, 6)
  w.w(1, 1)
  w.w(0, k - 1)
  w.w(1, 1)
  let eff = bps - k
  w.w((value >> k) & ((1 << eff) - 1), eff)
  w.bytes()
}

///|
/// 拼装帧：帧头 + 子帧字节 + 零填充 + CRC-16。
fn tb_pack_frame(header : Bytes, subframes : Bytes) -> Bytes {
  let w = TestBW::new()
  for i in 0..<header.length() {
    w.w(header.unsafe_get(i).to_int(), 8)
  }
  for i in 0..<subframes.length() {
    w.w(subframes.unsafe_get(i).to_int(), 8)
  }
  let body = w.bytes()
  let w2 = TestBW::new()
  for i in 0..<body.length() {
    w2.w(body.unsafe_get(i).to_int(), 8)
  }
  let c = crc16_range(body, 0, body.length())
  w2.w(c >> 8, 8)
  w2.w(c & 0xFF, 8)
  w2.bytes()
}

///|
/// 拼整文件。
fn tb_flac(header : Bytes, frames : Array[Bytes]) -> Bytes {
  let w = TestBW::new()
  for i in 0..<header.length() {
    w.w(header.unsafe_get(i).to_int(), 8)
  }
  for f in frames {
    for i in 0..<f.length() {
      w.w(f.unsafe_get(i).to_int(), 8)
    }
  }
  w.bytes()
}

///|
/// 用库内解码器解一个裸子帧，返回全部样本。
fn tb_decode_subframe(
  subframes : Bytes,
  block_size : Int32,
  bps : Int32,
) -> Array[Int64] raise FlacError {
  let br = BitReader::new(subframes)
  let xs = Array::make(block_size, 0L)
  decode_subframe(br, xs, block_size, bps)
  xs
}

///|
/// UTF-8 形变变长正整数（1..3 字节，覆盖测试所需范围）。
fn tb_utf8(w : TestBW, number : Int32) -> Unit {
  if number < 0x80 {
    w.w(number, 8)
  } else if number < 0x800 {
    w.w(0xC0 | (number >> 6), 8)
    w.w(0x80 | (number & 0x3F), 8)
  } else {
    w.w(0xE0 | (number >> 12), 8)
    w.w(0x80 | ((number >> 6) & 0x3F), 8)
    w.w(0x80 | (number & 0x3F), 8)
  }
}

///|
/// LPC 子帧（单分区 Rice，残差按给定精度系数现场计算）。
/// `shift_field` 是 5 位字段值（0..31），按规范 s(5) 解释：
/// >= 16 为负数（左移）。与 `reconstruct_lpc` 的语义一致。
fn tb_sub_lpc(
  samples : Array[Int32],
  bps : Int32,
  order : Int32,
  precision : Int32,
  coeffs : Array[Int32],
  shift_field : Int32,
) -> Bytes {
  let w = TestBW::new()
  w.w(0, 1)
  w.w(0b100000 | (order - 1), 6)
  w.w(0, 1)
  let mask = (1 << bps) - 1
  for i in 0..<order {
    w.w(samples[i] & mask, bps)
  }
  w.w(precision - 1, 4)
  w.w(shift_field, 5)
  let cmask = (1 << precision) - 1
  for c in coeffs {
    w.w(c & cmask, precision)
  }
  // 残差（与库端重建公式同源——这里验证的是布局，正确性由差分语料兜底）
  let shift = if shift_field >= 16 { shift_field - 32 } else { shift_field }
  let res = []
  for i in order..<samples.length() {
    let mut acc = 0L
    for j in 0..<order {
      acc += Int64::from_int(coeffs[j]) * Int64::from_int(samples[i - 1 - j])
    }
    let pred = if shift >= 0 {
      (acc >> shift).to_int()
    } else {
      (acc << -shift).to_int()
    }
    res.push(Int64::from_int(samples[i] - pred))
  }
  w.w(0, 2)
  w.w(0, 4)
  w.w(7, 4)
  for r in res {
    let z = tb_zigzag(r)
    let q = (z >> 7).to_int()
    for _ in 0..<q {
      w.w(0, 1)
    }
    w.w(1, 1)
    w.w((z & 0x7FL).to_int(), 7)
  }
  w.bytes()
}

///|
/// 字节序列构造（白盒测试里替代字节转义字面量）。
fn tb_bytes(vals : Array[Int32]) -> Bytes {
  let w = TestBW::new()
  for v in vals {
    w.w(v, 8)
  }
  w.bytes()
}

///|
/// 16 字节全零 MD5（= STREAMINFO 未记录）。
fn zeromd5() -> Bytes {
  tb_bytes([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
}

///|
/// magic + STREAMINFO（可带 MD5）+ 任意附加块序列（最后一块置 last 标志）。
fn tb_flac_blocks(
  block_size : Int32,
  rate : Int32,
  ch : Int32,
  bps : Int32,
  total : Int64,
  md5 : Bytes,
  extras : Array[(Int32, Bytes)],
) -> Bytes {
  let w = TestBW::new()
  w.w(0x66, 8)
  w.w(0x4C, 8)
  w.w(0x61, 8)
  w.w(0x43, 8)
  let info = tb_streaminfo(block_size, rate, ch, bps, total, md5)
  w.w(if extras.length() == 0 { 1 } else { 0 }, 1)
  w.w(0, 7)
  w.w(info.length(), 24)
  for i in 0..<info.length() {
    w.w(info.unsafe_get(i).to_int(), 8)
  }
  for i in 0..<extras.length() {
    let (typ, payload) = extras[i]
    w.w(if i == extras.length() - 1 { 1 } else { 0 }, 1)
    w.w(typ, 7)
    w.w(payload.length(), 24)
    for k in 0..<payload.length() {
      w.w(payload.unsafe_get(k).to_int(), 8)
    }
  }
  w.bytes()
}

///|
/// 写小端 u32（VORBIS_COMMENT 的长度前缀用）。
fn tb_le32(w : TestBW, v : Int32) -> Unit {
  w.w(v & 0xFF, 8)
  w.w((v >> 8) & 0xFF, 8)
  w.w((v >> 16) & 0xFF, 8)
  w.w((v >> 24) & 0xFF, 8)
}

///|
/// 写大端 u32（PICTURE 等；要求 v < 2^31）。
fn tb_be32(w : TestBW, v : Int32) -> Unit {
  w.w64(Int64::from_int(v), 32)
}

///|
/// 写大端 u64（SEEKTABLE 用；-1L 即占位点的全 1 样本号）。
fn tb_be64(w : TestBW, v : Int64) -> Unit {
  w.w64(v, 64)
}
