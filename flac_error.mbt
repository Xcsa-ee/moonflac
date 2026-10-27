// flac_error.mbt
//
// FLAC 解码的错误类型。FLAC 文件是外部不可信输入：截断、非法字段、
// 校验失败都必须落到结构化错误上，绝不能 panic。
//
// 本类型不设"合法但未实现"的变体：RFC 9639 规定的合法解码路径已全部
// 实现，解码器遇到的非 Truncated 错误都表示码流违反规范。

///|
/// 解码过程中可能出现的错误。
pub suberror FlacError {
  /// 数据长度不足（文件被截断）。
  Truncated(offset~ : Int32, need~ : Int32, actual~ : Int32)
  /// 文件开头不是 `fLaC` 魔数。
  NotFlac
  /// 元数据块（含 STREAMINFO）字段非法。
  BadMetadata(reason~ : String)
  /// 帧头字段非法。
  BadFrameHeader(reason~ : String)
  /// CRC-8 / CRC-16 校验失败。
  BadCrc(kind~ : String, expected~ : Int32, actual~ : Int32)
  /// 子帧头或子帧数据非法。
  BadSubframe(reason~ : String)
  /// 残差分区编码非法。
  BadResidual(reason~ : String)
  /// STREAMINFO 记录的 MD5 与解码 PCM 不符（数据已损坏）。
  Md5Mismatch(expected~ : String, actual~ : String)
}
