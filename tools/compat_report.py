"""兼容性验收报告：本解码器 vs libFLAC vs FFmpeg 三方一致性检查。

对每个 FLAC 文件：
1. 本解码器（moon run cmd/main）解码 → WAV → 逐样本；
2. FFmpeg 解码 → f64le → 逐样本比对（全位深）；
3. `flac -t` 完整解码 + STREAMINFO MD5 校验（libFLAC 作为独立第三方）；
4. `flac -d --force-raw-format` 裸 PCM 逐字节比对（仅 8 的倍数位深；
   libFLAC 对 12/20 位拒绝 raw 输出）。

用法:
    python tools/compat_report.py --xiph <xiph flac test 目录> \
        [--corpus tools/corpus] [--out COMPATIBILITY.md] [--target wasm-gc]
"""

import json
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPUS = os.path.join(HERE, "corpus")

sys.path.insert(0, HERE)
import diff_oracle as d  # noqa: E402


def find_flac():
    env = os.environ.get("FLAC_BIN")
    if env and os.path.exists(env):
        return env
    for base in (ROOT, os.path.dirname(ROOT)):
        local = os.path.join(base, "_ffmpeg", "_dl", "flac-win",
                             "flac-1.5.0-win", "Win64", "flac.exe")
        if os.path.exists(local):
            return local
    return "flac"


FLAC = find_flac()


def flac_test(path):
    """`flac -t`：完整解码 + MD5 校验。返回 (ok, 消息)。"""
    r = subprocess.run([FLAC, "-t", path],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1:] and \
        (r.stdout + r.stderr).strip().splitlines()[-1] or ""


def flac_raw(path, bps, out_path):
    """`flac -d` 到裸 PCM；12/20 位等非 8 倍数位深返回 (None, 原因)。"""
    if bps % 8 != 0:
        return None, "libFLAC 拒绝 raw 输出（非 8 倍数位深）"
    code = {8: "s8", 16: "s16", 24: "s24", 32: "s32"}[bps]
    r = subprocess.run(
        [FLAC, "-d", "-f", "--force-raw-format", "--endian=little",
         "--sign=signed", "-o", out_path, path],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return None, f"flac -d 失败: {r.stderr.strip()[:120]}"
    data = open(out_path, "rb").read()
    os.remove(out_path)
    nbytes = bps // 8
    return [int.from_bytes(data[i:i + nbytes], "little", signed=True)
            for i in range(0, len(data), nbytes)], ""


def check_file(path, target):
    """返回一行结果 dict。"""
    row = {"file": os.path.basename(path)}
    wav = path + ".compat.wav"
    try:
        out = d.run_cli(path, wav, target)
        bps = d.streaminfo_bps(path)
        row["bps"] = bps
        if "解码失败" in out:
            row["ours"] = f"解码失败: {out.strip()[:80]}"
            return row
        bits, ch, rate, ours = d.read_wav(wav)
        row["channels"] = ch
        shift = bits - bps
        if shift:
            ours = [[v >> shift for v in c] for c in ours]
        flat = [ours[c][f] for f in range(len(ours[0])) for c in range(ch)]
        row["samples"] = len(flat) // ch
        # vs ffmpeg
        oints, err = d.oracle_ints(path, bps)
        if err:
            row["vs_ffmpeg"] = err
        elif len(flat) != len(oints):
            row["vs_ffmpeg"] = f"样本数不符 {len(flat)} vs {len(oints)}"
        else:
            row["vs_ffmpeg"] = "一致" if all(
                a == b for a, b in zip(flat, oints)) else "不一致"
        # vs libFLAC：-t（解码+MD5）
        ok, msg = flac_test(path)
        row["flac_t"] = "ok" if ok else f"失败: {msg[:80]}"
        # vs libFLAC：raw 逐样本
        rints, rerr = flac_raw(path, bps, wav + ".raw")
        if rints is None:
            row["vs_flac"] = rerr
        elif len(rints) != len(flat):
            row["vs_flac"] = f"样本数不符 {len(flat)} vs {len(rints)}"
        else:
            row["vs_flac"] = "一致" if all(
                a == b for a, b in zip(flat, rints)) else "不一致"
    except Exception as e:  # noqa: BLE001
        row["error"] = str(e)[:120]
    finally:
        if os.path.exists(wav):
            os.remove(wav)
    return row


def main():
    xiph = corpus = out = None
    target = "wasm-gc"
    args = sys.argv[1:]
    def opt(name):
        return args[args.index(name) + 1] if name in args else None
    xiph = opt("--xiph")
    corpus = opt("--corpus")
    out = opt("--out")
    if opt("--target"):
        target = opt("--target")

    files = []
    if xiph:
        for root, _, names in os.walk(xiph):
            for n in sorted(names):
                if n.lower().endswith(".flac"):
                    files.append(os.path.join(root, n))
    if corpus and os.path.isdir(corpus):
        manifest = os.path.join(corpus, "manifest.json")
        if os.path.exists(manifest):
            for case in json.load(open(manifest, encoding="utf-8")):
                if case["kind"] == "decode":
                    files.append(os.path.join(corpus, case["name"] + ".flac"))
        else:
            for n in sorted(os.listdir(corpus)):
                if n.endswith(".flac"):
                    files.append(os.path.join(corpus, n))

    print(f"检查 {len(files)} 个文件（target={target}, flac={FLAC}）")
    rows = [check_file(f, target) for f in files]

    n_ok = sum(1 for r in rows
               if r.get("vs_ffmpeg") == "一致" and r.get("flac_t") == "ok")
    n_raw_ok = sum(1 for r in rows if r.get("vs_flac") == "一致")
    n_raw_skip = sum(1 for r in rows
                     if r.get("vs_flac") and r.get("vs_flac") != "一致")

    lines = []
    lines.append("# moonflac 兼容性验收报告")
    lines.append("")
    lines.append("自动生成（`python tools/compat_report.py`），请勿手改。")
    lines.append("")
    lines.append("## 方法与口径")
    lines.append("")
    lines.append("- **本解码器**：`moon run cmd/main` 解码为 WAV，读回样本；")
    lines.append("- **FFmpeg**：解码为 f64le 裸流，按 STREAMINFO 位深还原整数，逐样本比对；")
    lines.append("- **libFLAC**：`flac -t` 做完整解码 + STREAMINFO MD5 校验；"
                 "8 的倍数位深另做 `flac -d --force-raw-format` 裸 PCM 逐样本比对"
                 "（libFLAC 对 12/20 位拒绝 raw 输出，属工具限制，已如实标注）。")
    lines.append("")
    lines.append("## 结果")
    lines.append("")
    lines.append(f"- 文件总数：{len(rows)}")
    lines.append(f"- 与 FFmpeg 逐样本一致且 `flac -t` 通过：{n_ok}")
    lines.append(f"- 与 libFLAC 裸 PCM 逐样本一致：{n_raw_ok}")
    if n_raw_skip:
        lines.append(f"- 未做 libFLAC 裸 PCM 比对（工具限制）：{n_raw_skip}")
    lines.append("")
    lines.append("| 文件 | bps | 声道 | 样本/声道 | vs FFmpeg | flac -t | vs libFLAC raw |")
    lines.append("|---|---|---|---|---|---|---|")
    for r in rows:
        lines.append(
            f"| {r['file']} | {r.get('bps', '?')} | {r.get('channels', '?')} "
            f"| {r.get('samples', '?')} | {r.get('vs_ffmpeg', r.get('ours', '?'))} "
            f"| {r.get('flac_t', '?')} | {r.get('vs_flac', r.get('ours', '?'))} |")
    text = "\n".join(lines) + "\n"
    if out:
        open(out, "w", encoding="utf-8").write(text)
        print(f"报告已写入 {out}")
    else:
        print(text)
    fails = [r for r in rows
             if r.get("vs_ffmpeg") not in ("一致", None)
             or r.get("flac_t") not in ("ok", None)
             or r.get("vs_flac") not in ("一致", None)
             and not (r.get("vs_flac") or "").startswith(
                 "libFLAC 拒绝 raw 输出")]
    if fails:
        print(f"有 {len(fails)} 个文件未通过，详见报告")
        sys.exit(1)


if __name__ == "__main__":
    main()
