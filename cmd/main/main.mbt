// cmd/main/main.mbt
//
// 命令行入口：读 .flac 文件 → 解码 → 输出 WAV。

///|
/// 解码 + 写 WAV；FlacError 在此折叠为可读错误消息。
fn decode_and_write(data : Bytes, output : String) -> Unit {
  try {
    let file = @moonflac.decode(data)
    let frames = if file.channels.length() > 0 {
      file.channels[0].length()
    } else {
      0
    }
    println(
      "采样率: \{file.info.sample_rate} Hz, 声道: \{file.info.channels}, 位深: \{file.info.bits_per_sample}, 样本: \{frames}",
    )
    let wav = @moonflac.wav_encode(
      file.channels,
      file.info.bits_per_sample,
      file.info.sample_rate,
    )
    @fs.write_bytes_to_file(output, wav)
    println("已写入: \{output}")
  } catch {
    e => println("解码失败: \{e}")
  }
}

///|
fn main {
  let args = @env.args()
  // 各后端 argv 形状不同：wasm-gc/native 是 [程序, 输入, 输出]，
  // js 是 [node, 脚本.js, 输入, 输出]——跳过程序路径后取参数。
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base >= args.length() {
    println("用法: moon run cmd/main -- <input.flac> [output.wav]")
    return
  }
  let input = args[base]
  let output = if base + 1 < args.length() {
    args[base + 1]
  } else {
    "\{input}.wav"
  }
  try {
    let data = @fs.read_file_to_bytes(input)
    decode_and_write(data, output)
  } catch {
    @fs.IOError::IOError(msg) => println("I/O 错误: \{msg}")
  }
}
