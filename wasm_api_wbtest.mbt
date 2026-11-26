// wasm_api_wbtest.mbt
//
// wasm 导出面的契约：base64 FLAC → base64 WAV；坏输入返回空串（不 panic）。

///|
test "decode_flac_base64：合法 FLAC 返回非空 base64 WAV" {
  let hdr = tb_frame_header(64, 44100, 0, 16, 0, 0, 9)
  let data = tb_flac(tb_flac_header(64, 44100, 1, 16, 64L, false), [
    tb_pack_frame(hdr, tb_sub_constant(7, 16)),
  ])
  let out = decode_flac_base64(@base64.encode(data))
  @test.assert_eq(out.length() > 0, true)
  let wav = @base64.decode(out)
  // RIFF 头：'R' 'I' 'F' 'F' .... 'W' 'A' 'V' 'E'
  @test.assert_eq(wav.unsafe_get(0).to_int(), 0x52)
  @test.assert_eq(wav.unsafe_get(1).to_int(), 0x49)
  @test.assert_eq(wav.unsafe_get(8).to_int(), 0x57)
  @test.assert_eq(wav.unsafe_get(9).to_int(), 0x41)
  // 64 样本 × 1 声道 × 16 位 = 128 字节 PCM，加 44 字节头
  @test.assert_eq(wav.length(), 44 + 128)
}

///|
test "decode_flac_base64：坏输入返回空串，不 panic" {
  @test.assert_eq(decode_flac_base64(""), "")
  @test.assert_eq(decode_flac_base64("!!!not-base64!!!"), "")
  @test.assert_eq(decode_flac_base64(@base64.encode(b"not a flac")), "")
}
