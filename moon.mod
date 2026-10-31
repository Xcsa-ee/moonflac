name = "Xcsa-ee/moonflac"

version = "0.3.3"

readme = "README.md"

repository = "https://github.com/Xcsa-ee/moonflac"

license = "Apache-2.0"

keywords = [ "flac", "audio", "decoder", "codec", "lossless", "wasm" ]

description = "纯 MoonBit 实现的 FLAC 无损音频解码器，不依赖任何 C 库或系统编解码器"

preferred_target = "wasm-gc"

import {
  "moonbitlang/x@0.5.5",
}
