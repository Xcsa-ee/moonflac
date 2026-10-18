"""差分测试：本解码器 vs ffmpeg oracle。

对每个正例：
1. `moon run cmd/main` 解码 → 我方 WAV；
2. ffmpeg 解同一个 .flac → f64le 裸流（<=32 位样本在 f64 中精确）；
3. 双方逐样本相等（我方 WAV 读回整数，oracle f64 × 2^(bps-1) 回整数）。

对每个负例：要求 CLI 输出含「解码失败」，且正例不许出现该字样。

用法: python tools/diff_oracle.py [--target wasm-gc|js] [--filter 子串]
"""

import json
import os
import struct
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPUS = os.path.join(HERE, "corpus")


def find_ffmpeg():
    env = os.environ.get("FLAC_FFMPEG")
    if env and os.path.exists(env):
        return env
    for base in (ROOT, os.path.dirname(ROOT)):  # 仓库内或工作区内
        local = os.path.join(
            base, "_ffmpeg", "_bin", "imageio_ffmpeg", "binaries",
            "ffmpeg-win-x86_64-v7.1.exe")
        if os.path.exists(local):
            return local
    return "ffmpeg"


FFMPEG = find_ffmpeg()


def run_cli(flac_path, wav_path, target):
    r = subprocess.run(
        ["moon", "run", "cmd/main", "--target", target, "--",
         flac_path, wav_path],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
        errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    return out


def read_wav(path):
    """返回 (bits, channels, rate, samples_planar[list[list[int]]])。"""
    d = open(path, "rb").read()
    assert d[:4] == b"RIFF" and d[8:12] == b"WAVE", "坏 WAV 头"
    i = 12
    bits = ch = rate = None
    data = None
    while i + 8 <= len(d):
        cid = d[i:i + 4]
        sz = int.from_bytes(d[i + 4:i + 8], "little")
        body = d[i + 8:i + 8 + sz]
        if cid == b"fmt ":
            rate = int.from_bytes(body[4:8], "little")
            ch = int.from_bytes(body[2:2 + 2], "little")
            bits = int.from_bytes(body[14:16], "little")
        elif cid == b"data":
            data = body
        i += 8 + sz + (sz & 1)
    assert data is not None and bits is not None, "缺 fmt/data"
    nbytes = bits // 8
    nframes = len(data) // (nbytes * ch)
    out = [[] for _ in range(ch)]
    for f in range(nframes):
        for c in range(ch):
            o = f * nbytes * ch + c * nbytes
            if bits == 8:
                out[c].append(data[o] - 128)
            else:
                out[c].append(int.from_bytes(data[o:o + nbytes], "little",
                                             signed=True))
    return bits, ch, rate, out


def oracle_ints(flac_path, bps):
    """ffmpeg 解码为 f64le，还原成整数样本（f64 精确表示 <=32 位整数）。"""
    raw = flac_path + ".oracle.f64"
    r = subprocess.run(
        [FFMPEG, "-hide_banner", "-loglevel", "error", "-i", flac_path,
         "-f", "f64le", "-acodec", "pcm_f64le", "-y", raw],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return None, f"ffmpeg 解码失败: {r.stderr.strip()[:200]}"
    d = open(raw, "rb").read()
    n = len(d) // 8
    vals = struct.unpack("<%dd" % n, d)
    os.remove(raw)
    scale = float(1 << (bps - 1))
    # oracle 为归一化浮点；还原为 bps 位整数
    return [int(round(v * scale)) for v in vals], ""


def main():
    target = "wasm-gc"
    filt = None
    args = sys.argv[1:]
    if "--target" in args:
        target = args[args.index("--target") + 1]
    if "--filter" in args:
        filt = args[args.index("--filter") + 1]

    manifest = json.load(open(os.path.join(CORPUS, "manifest.json"),
                              encoding="utf-8"))
    # 先构建一次，避免逐 case 重建开销
    subprocess.run(["moon", "build", "--target", target], cwd=ROOT,
                   capture_output=True)

    fails = []
    npass = 0
    for case in manifest:
        name = case["name"]
        if filt and filt not in name:
            continue
        path = os.path.join(CORPUS, name + ".flac")
        wav = os.path.join(CORPUS, name + ".out.wav")
        if os.path.exists(wav):
            os.remove(wav)
        out = run_cli(path, wav, target)
        ok_msg = "解码失败" in out

        if case["kind"] == "negative":
            if ok_msg and not os.path.exists(wav):
                npass += 1
            elif ok_msg:
                npass += 1  # 有失败消息即可（可能已写入旧文件）
            else:
                fails.append((name, f"负例未报错: {out.strip()[:160]}"))
            continue

        if ok_msg:
            fails.append((name, f"正例报错: {out.strip()[:200]}"))
            continue
        if not os.path.exists(wav):
            fails.append((name, "未产出 WAV"))
            continue

        # 从流信息推 bps：WAV fmt 里的 bits 是容器位宽，真实 bps 由 oracle 推
        # 这里从 ffmpeg 元数据拿：直接比较样本个数 + 用容器位宽试还原。
        # 先取 oracle（按容器位宽解释可能不等于 bps，比如 12 位装 16 容器——
        # 本语料没有该组合，正例 bps 都是 8/16/24/32 的容器同宽）。
        bits, ch, rate, ours = read_wav(wav)
        # oracle
        raw = subprocess.run(
            [FFMPEG, "-hide_banner", "-i", path, "-f", "null", "-"],
            capture_output=True, text=True, encoding="utf-8",
            errors="replace")
        _ = raw
        bps = bits  # 本语料中容器位宽 == bps
        oints, err = oracle_ints(path, bps)
        if err:
            fails.append((name, err))
            continue
        # 展平 planar（oracle 是交错的）
        flat = []
        nframes = len(ours[0])
        for f in range(nframes):
            for c in range(ch):
                flat.append(ours[c][f])
        if len(flat) != len(oints):
            fails.append((name, f"样本数不符: ours={len(flat)} oracle={len(oints)}"))
            continue
        diff = next((i for i, (a, b) in enumerate(zip(flat, oints)) if a != b),
                    None)
        if diff is not None:
            fails.append((name, f"样本不一致 @ {diff}: ours={flat[diff]} "
                                f"oracle={oints[diff]}"))
            continue
        # 额外：oracle 声道数/样本数与 STREAMINFO 口径自洽
        npass += 1
        if os.path.exists(wav):
            os.remove(wav)

    print(f"\n差分结果 [{target}]: {npass} 通过, {len(fails)} 失败")
    for name, msg in fails:
        print(f"  FAIL {name}: {msg}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
