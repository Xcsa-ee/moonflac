// incremental_wbtest.mbt
//
// 增量流式解码判据：按各种块大小喂入（含逐字节），解出的样本必须与
// 整文件 decode 逐样本一致；提前 finish() 截断、total_samples 未知等
// 边界行为也要覆盖。

///|
/// 把解出的多个块拼成完整 planar 输出（每声道一个数组）。
fn concat_blocks(
  blocks : Array[Array[Array[Int32]]],
  channels : Int32,
) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  for _ in 0..<channels {
    out.push([])
  }
  for b in blocks {
    for c in 0..<channels {
      for x in b[c] {
        out[c].push(x)
      }
    }
  }
  out
}

///|
/// 反复调用 next() 直到返回 None，把所有块追加进 blocks。
fn drain(
  f : FlacFeeder,
  blocks : Array[Array[Array[Int32]]],
) -> Unit raise FlacError {
  while true {
    match f.next() {
      Some(b) => blocks.push(b)
      None => return
    }
  }
}

///|
/// 按固定块大小切分喂入，边喂边解，返回全部块。
fn feed_chunked(
  data : Bytes,
  chunk_size : Int32,
) -> Array[Array[Array[Int32]]] raise FlacError {
  let f = FlacFeeder::new()
  let blocks : Array[Array[Array[Int32]]] = []
  let mut i = 0
  while i < data.length() {
    let end = if i + chunk_size < data.length() {
      i + chunk_size
    } else {
      data.length()
    }
    let w = @buffer.Buffer()
    for k in i..<end {
      w.write_byte(data.unsafe_get(k))
    }
    f.feed(w.to_bytes())
    drain(f, blocks)
    i = end
  }
  f.finish()
  drain(f, blocks)
  blocks
}

///|
/// 确定性伪随机块大小序列（LCG），避免测试结果不稳定。
fn feed_pseudorandom(
  data : Bytes,
  seed : Int32,
) -> Array[Array[Array[Int32]]] raise FlacError {
  let f = FlacFeeder::new()
  let blocks : Array[Array[Array[Int32]]] = []
  let mut state = seed
  let mut i = 0
  while i < data.length() {
    state = (state * 1103515245 + 12345) & 0x3FFFFFFF
    let chunk = state % 17 + 1
    let end = if i + chunk < data.length() { i + chunk } else { data.length() }
    let w = @buffer.Buffer()
    for k in i..<end {
      w.write_byte(data.unsafe_get(k))
    }
    f.feed(w.to_bytes())
    drain(f, blocks)
    i = end
  }
  f.finish()
  drain(f, blocks)
  blocks
}

///|
/// 断言 `got` 与 `want` 每声道逐样本一致，不一致即 abort。
fn assert_channels_eq(
  got : Array[Array[Int32]],
  want : Array[Array[Int32]],
  label : String,
) -> Unit {
  if got.length() != want.length() {
    abort(
      "\{label}: 声道数不一致 got \{got.length()} want \{want.length()}",
    )
  }
  for c in 0..<want.length() {
    if got[c].length() != want[c].length() {
      abort(
        "\{label}: 声道 \{c} 样本数不一致 got \{got[c].length()} want \{want[c].length()}",
      )
    }
    for i in 0..<want[c].length() {
      if got[c][i] != want[c][i] {
        abort(
          "\{label}: 声道 \{c} 样本 \{i} 不一致: got \{got[c][i]} want \{want[c][i]}",
        )
      }
    }
  }
}

///|
/// 内部消化 FlacError（转成 abort），让本函数签名无需声明任何 raise。
fn safe_decode(data : Bytes) -> FlacFile {
  decode(data) catch {
    _ => abort("整文件解码不应失败")
  }
}

///|
/// 内部消化 FlacError（转成 abort）。
fn safe_feed_chunked(
  data : Bytes,
  chunk_size : Int32,
) -> Array[Array[Array[Int32]]] {
  feed_chunked(data, chunk_size) catch {
    _ => abort("增量解码不应失败")
  }
}

///|
/// 内部消化 FlacError（转成 abort）。
fn safe_feed_pseudorandom(
  data : Bytes,
  seed : Int32,
) -> Array[Array[Array[Int32]]] {
  feed_pseudorandom(data, seed) catch {
    _ => abort("增量解码不应失败")
  }
}

///|
/// 断言增量解码的拼接结果与整文件 decode 完全一致。
fn assert_matches_whole_file(data : Bytes, label : String) -> Unit {
  let whole = safe_decode(data)
  let channels = whole.channels.length()
  let sizes = [1, 3, 7, 64, 1024]
  for size in sizes {
    let blocks = safe_feed_chunked(data, size)
    let got = concat_blocks(blocks, channels)
    assert_channels_eq(got, whole.channels, "\{label}（块大小 \{size}）")
  }
  // 伪随机块大小也要一致
  let rand_blocks = safe_feed_pseudorandom(data, 42)
  let rand_got = concat_blocks(rand_blocks, channels)
  assert_channels_eq(rand_got, whole.channels, "\{label}（伪随机块）")
}

///|
test "增量解码：多帧常数流与整文件一致" {
  let frames = []
  for i in 0..<4 {
    let hdr = tb_frame_header(64, 44100, 0, 16, i, 0, 9)
    frames.push(tb_pack_frame(hdr, tb_sub_constant(i - 2, 16)))
  }
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 256L, false), frames)
  assert_matches_whole_file(data, "多帧常数流")
}

///|
test "增量解码：verbatim 变长帧号（3 字节编号）" {
  // 编号超过 0x800 触发 3 字节变长帧号路径
  let frames = []
  for i in 0..<3 {
    let hdr = tb_frame_header(16, 44100, 0, 16, 0x900 + i, 0, 9)
    let samples = [
      i * 100,
      -(i * 100),
      123,
      -123,
      32767,
      -32768,
      0,
      7,
      50,
      -50,
      8000,
      -8000,
      100,
      -100,
      200,
      -200,
    ]
    frames.push(tb_pack_frame(hdr, tb_sub_verbatim(samples, 16)))
  }
  let data = tb_flac(tb_flac_header(16, 44100, 1, 16, 48L, false), frames)
  assert_matches_whole_file(data, "变长帧号")
}

///|
test "增量解码：mid/side 双声道" {
  let left = [
    1000, -2000, 3000, -30000, 32767, -32768, 0, 7, 50, -50, 8000, -8000, 100, -100,
    200, -200,
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
  assert_matches_whole_file(data, "mid/side")
}

///|
test "增量解码：total_samples 未知（0）也能解完" {
  let frames = []
  for i in 0..<3 {
    let hdr = tb_frame_header(64, 44100, 0, 16, i, 0, 9)
    frames.push(tb_pack_frame(hdr, tb_sub_constant(i, 16)))
  }
  // total=0 表示未知
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 0L, false), frames)
  let f = FlacFeeder::new()
  f.feed(data)
  let blocks : Array[Array[Array[Int32]]] = []
  drain(f, blocks)
  f.finish()
  drain(f, blocks)
  @test.assert_eq(f.is_done(), true)
  let got = concat_blocks(blocks, 1)
  @test.assert_eq(got[0].length(), 192)
  @test.assert_eq(got[0][0], 0)
  @test.assert_eq(got[0][64], 1)
  @test.assert_eq(got[0][128], 2)
}

///|
test "增量解码：提前 finish() 且 total_samples 已知时报 Truncated" {
  let frames = []
  for i in 0..<4 {
    let hdr = tb_frame_header(64, 44100, 0, 16, i, 0, 9)
    frames.push(tb_pack_frame(hdr, tb_sub_constant(i, 16)))
  }
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 256L, false), frames)
  let f = FlacFeeder::new()
  // 只喂到倒数第二个字节（完整喂入已知可解出全部 4 帧，故意少 1 字节）
  let w = @buffer.Buffer()
  for i in 0..<(data.length() - 1) {
    w.write_byte(data.unsafe_get(i))
  }
  f.feed(w.to_bytes())
  let blocks : Array[Array[Array[Int32]]] = []
  drain(f, blocks)
  try {
    f.finish()
    abort("提前 finish 且未解满应报 Truncated")
  } catch {
    FlacError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "增量解码：未 finish 就取完剩余数据不报错" {
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 64L, false), [
    tb_pack_frame(hdr, tb_sub_constant(42, 16)),
  ])
  let f = FlacFeeder::new()
  f.feed(data)
  let blocks : Array[Array[Array[Int32]]] = []
  drain(f, blocks)
  // total_samples 已满足，next() 已自行置 eof，无需显式 finish
  @test.assert_eq(f.is_done(), true)
  let got = concat_blocks(blocks, 1)
  @test.assert_eq(got[0].length(), 64)
  @test.assert_eq(got[0][0], 42)
}
