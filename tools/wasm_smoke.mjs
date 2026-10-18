#!/usr/bin/env node
// tools/wasm_smoke.mjs
//
// WASM 运行时冒烟测试：在 Node 里真正加载 wasm、解一个 FLAC、验 WAV 并写出。
// 与单元/差分测试互补——那些在测试进程里直接调 MoonBit 代码，这个跑的是
// 发布形态的 wasm 产物 + base64 跨边界调用，能抓到导出名、字符串内置、
// 导入表一类只在实例化时才暴露的问题。
//
// 需要支持 WebAssembly JS String Builtins 的 Node（V8 12.6+，即 Node 22+）。
//
// 用法:
//   node tools/wasm_smoke.mjs [out.wav] [wasm] [flac]
// 参数可省略：wasm 默认取 release 构建产物，flac 默认取生成的差分语料。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outPath = path.resolve(
  process.argv[2] ?? path.join(os.tmpdir(), "moonflac-wasm-smoke.wav"),
);
const wasmPath = path.resolve(
  process.argv[3] ??
    path.join(REPO, "_build", "wasm-gc", "release", "build", "moonflac.wasm"),
);
const flacPath = path.resolve(
  process.argv[4] ?? path.join(REPO, "tools", "corpus", "sine16_2000.flac"),
);

function fail(msg) {
  console.error(`失败: ${msg}`);
  process.exit(1);
}

let exports;
try {
  const module = await WebAssembly.compile(fs.readFileSync(wasmPath), {
    builtins: ["js-string"],
    importedStringConstants: "_",
  });
  ({ exports } = await WebAssembly.instantiate(module, {}));
} catch (e) {
  fail(`${wasmPath} 编译或实例化失败: ${e.message}`);
}

if (typeof exports.decode_flac_base64 !== "function") {
  fail(`${wasmPath} 没有导出 decode_flac_base64`);
}

const encoded = exports.decode_flac_base64(
  fs.readFileSync(flacPath).toString("base64"),
);
if (typeof encoded !== "string" || encoded.length === 0) {
  fail(`${wasmPath} 解 ${flacPath} 返回空字符串`);
}

const wav = Buffer.from(encoded, "base64");
const riff = wav.subarray(0, 4).toString("latin1");
const wave = wav.subarray(8, 12).toString("latin1");
if (wav.length < 44 || riff !== "RIFF" || wave !== "WAVE") {
  fail(`结果不是合法 WAV（前 4 字节 "${riff}"，8-12 字节 "${wave}"）`);
}
const declared = wav.readUInt32LE(4) + 8;
if (declared !== wav.length) {
  fail(`WAV 的 RIFF 长度字段是 ${declared}，实际 ${wav.length} 字节`);
}

// 负例：非 FLAC 数据必须返回空串而不是抛异常
const bad = exports.decode_flac_base64(Buffer.from("RIFFjunk").toString("base64"));
if (bad !== "") {
  fail("负例（RIFF 头）未返回空字符串");
}

fs.writeFileSync(outPath, wav);
console.log(
  `OK: ${path.relative(REPO, flacPath)} -> ${outPath}（${wav.length} 字节）`,
);
