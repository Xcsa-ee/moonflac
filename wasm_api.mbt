// wasm_api.mbt
//
// 供浏览器 WASM demo 调用的导出接口：base64 FLAC → base64 WAV。
// 用 base64 字符串跨 JS 边界，避免直接操作线性内存。

///|
/// 解码 base64 编码的 FLAC 数据，返回 base64 编码的 PCM WAV
/// （容器位宽 = 流的位深，8/16/24/32）。
/// 解码失败返回空字符串，调用方据此判断是否成功。
pub fn decode_flac_base64(flac_b64 : String) -> String {
  try {
    let data = @base64.decode(flac_b64)
    let file = decode(data)
    let wav = wav_encode(
      file.channels,
      file.info.bits_per_sample,
      file.info.sample_rate,
    )
    @base64.encode(wav)
  } catch {
    _ => ""
  }
}
