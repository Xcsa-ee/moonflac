"""生成 FLAC 差分测试语料。

两个来源：
1. ffmpeg 编码合成 PCM —— 覆盖真实编码器会产出的结构组合；
2. 手造最小合法帧 —— 覆盖 ffmpeg 编码器不会产出的路径
   （rice 转义、采样率扩展码、可变块长、wasted bits 的部分形态等）。

输出：tools/corpus/*.flac + tools/corpus/manifest.json（含 decode/negative 分类）。
所有手造约定均先经 ffmpeg 解码器验证（见 tasks/moonflac-计划.md §2）。
用法：python tools/gen_corpus.py [--ffmpeg <路径>]
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
    return "ffmpeg"  # CI / Linux


FFMPEG = None  # main 里解析


# ---------------------------------------------------------------- 位写入基座

class W:
    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def w(self, value, nbits):
        assert nbits == 0 or 0 <= value < (1 << nbits), (value, nbits)
        if nbits == 0:
            return
        self.acc = (self.acc << nbits) | value
        self.n += nbits
        while self.n >= 8:
            self.n -= 8
            self.out.append((self.acc >> self.n) & 0xFF)

    def align(self):
        if self.n:
            self.w(0, 8 - self.n)


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def crc16(data):
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x8005) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def utf8num(n):
    """帧号的 UTF-8 形变变长编码（1..7 字节）。"""
    if n < 0x80:
        return bytes([n])
    for length in range(2, 8):
        payload = 6 * (length - 1)
        if n < (1 << payload):
            lead = (0xFF << (8 - length)) & 0xFF
            if 8 - length - 1:
                lead |= n >> payload
            out = [lead]
            for i in range(length - 1, 0, -1):
                out.append(0x80 | ((n >> (6 * (i - 1))) & 0x3F))
            return bytes(out)
    raise ValueError(n)


def streaminfo(block_size, rate, channels, bps, total):
    body = bytearray()
    body += struct.pack(">HH", block_size, block_size)
    body += b"\x00\x00\x00\x00\x00\x00"
    packed = (rate << 44) | ((channels - 1) << 41) | ((bps - 1) << 36) | total
    body += packed.to_bytes(8, "big")
    body += b"\x00" * 16
    assert len(body) == 34
    return bytes(body)


def make_flac(frames_bytes, block_size, rate, channels, bps, total):
    out = bytearray(b"fLaC")
    info = streaminfo(block_size, rate, channels, bps, total)
    out += bytes([0x80]) + len(info).to_bytes(3, "big") + info
    for f in frames_bytes:
        out += f
    return bytes(out)


BS_CODE = {192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9,
           1024: 10, 2048: 11, 4096: 12, 8192: 13, 16384: 14, 32768: 15}
SR_CODE = {88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6,
           24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11}
# 位深码 0 表示「位数只在 STREAMINFO 里」——非 8 倍数位深（4..7）只能走这条，
# 表码里没有 4 bit。frame_bps_code 负责这个回退。
BPS_CODE = {8: 1, 12: 2, 16: 4, 20: 5, 24: 6, 32: 7}


def frame_bps_code(bps):
    """帧头里的位深码；4..7 无表码，返回 0（按 STREAMINFO 取）。"""
    return BPS_CODE.get(bps, 0)


def frame_header(block_size, rate, ch_assign, bps, number, variable=False,
                 sr_extra=None, sr_extra_bits=0):
    """sr_extra=(值, 位宽) 时走扩展采样率码（12/13/14 由 sr_extra_code 指定）。"""
    w = W()
    w.w(0b11111111111110, 14)
    w.w(0, 1)
    w.w(1 if variable else 0, 1)
    if block_size in BS_CODE:
        w.w(BS_CODE[block_size], 4)
        bs_extra = 0
    elif block_size - 1 < 256:
        w.w(6, 4)
        bs_extra = 8
    else:
        w.w(7, 4)
        bs_extra = 16
    if sr_extra is not None:
        w.w(sr_extra[2], 4)  # 采样率码 12/13/14
    elif rate in SR_CODE:
        w.w(SR_CODE[rate], 4)
    else:
        w.w(0, 4)
    w.w(ch_assign, 4)
    w.w(frame_bps_code(bps), 3)
    w.w(0, 1)
    for b in utf8num(number):
        w.w(b, 8)
    if bs_extra:
        w.w(block_size - 1, bs_extra)
    if sr_extra is not None:
        w.w(sr_extra[0], sr_extra[1])
    w.align()
    header = bytes(w.out)
    header += bytes([crc8(header)])
    return header


def pack_frame(header, subframes):
    body = header + subframes
    return body + struct.pack(">H", crc16(body))


# ---------------------------------------------------------------- 子帧

def sub_constant(value, bps):
    w = W()
    w.w(0, 1)
    w.w(0b000000, 6)
    w.w(0, 1)
    w.w(value & ((1 << bps) - 1), bps)
    w.align()
    return bytes(w.out)


def sub_verbatim(samples, bps):
    w = W()
    w.w(0, 1)
    w.w(0b000001, 6)
    w.w(0, 1)
    mask = (1 << bps) - 1
    for s in samples:
        w.w(s & mask, bps)
    w.align()
    return bytes(w.out)


def sub_constant_wasted(value, bps, k):
    w = W()
    w.w(0, 1)
    w.w(0b000000, 6)
    w.w(1, 1)
    w.w(0, k - 1)
    w.w(1, 1)
    eff = bps - k
    w.w((value >> k) & ((1 << eff) - 1), eff)
    w.align()
    return bytes(w.out)


def rice_bits(values, param):
    """zeros-first：q 个 0 + 终止 1 + param 位余数（zigzag 映射）。"""
    bits = []
    for v in values:
        z = (-2 * v - 1) if v < 0 else 2 * v
        q, r = z >> param, z & ((1 << param) - 1)
        bits.append((0, q))
        bits.append((1, 1))
        if param:
            bits.append((r, param))
    return bits


def sub_fixed(samples, bps, order, param, entropy_method=0, method_param_len=4,
               escape_raw_bits=None):
    """FIXED 子帧；escape_raw_bits 非 None 时用转义原码编码残差。"""
    w = W()
    w.w(0, 1)
    w.w(0b001000 | order, 6)
    w.w(0, 1)
    preds = [
        lambda s, i: s[i],
        lambda s, i: s[i] - s[i - 1],
        lambda s, i: s[i] - 2 * s[i - 1] + s[i - 2],
        lambda s, i: s[i] - 3 * s[i - 1] + 3 * s[i - 2] - s[i - 3],
        lambda s, i: s[i] - 4 * s[i - 1] + 6 * s[i - 2] - 4 * s[i - 3] + s[i - 4],
    ]
    mask = (1 << bps) - 1
    for s in samples[:order]:
        w.w(s & mask, bps)
    res = [preds[order](samples, i) for i in range(order, len(samples))]
    w.w(entropy_method, 2)
    w.w(0, 4)  # 分区序 0 -> 1 分区（参数与数据交错：先参数后数据）
    if escape_raw_bits is not None:
        w.w((1 << method_param_len) - 1, method_param_len)
        w.w(escape_raw_bits, 5)
        rmask = (1 << escape_raw_bits) - 1 if escape_raw_bits else 0
        for r in res:
            w.w(r & rmask, escape_raw_bits)
    else:
        w.w(param, method_param_len)
        for val, nbits in rice_bits(res, param):
            w.w(val, nbits)
    w.align()
    return bytes(w.out)


# ---------------------------------------------------------------- 信号

def sig_sine(n, rate=44100, freq=440.0, bps=16, amp=None):
    import math
    top = 1 << (bps - 1)
    a = amp if amp else top - 1
    return [int(a * math.sin(2 * math.pi * freq * i / rate)) for i in range(n)]


def sig_noise(n, bps=16, seed=1):
    top = 1 << (bps - 1)
    state = seed
    out = []
    for _ in range(n):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((state % (2 * top)) - top)
    return out


def sig_even(n, bps=16):
    """全偶数信号：自动触发 wasted bits。"""
    return [v & ~1 for v in sig_sine(n, bps=bps)]


def sig_scale4(n, bps=16):
    return [v & ~3 for v in sig_sine(n, bps=bps)]


def sig_ramp(n, bps=16):
    top = 1 << (bps - 1)
    return [((i * 37) % (2 * top)) - top for i in range(n)]


def sig_step(n, bps=16):
    top = (1 << (bps - 1)) - 1
    return [(-top if (i // 512) % 2 else top) for i in range(n)]


def sig_silence(n, bps=16):
    return [0] * n


# ---------------------------------------------------------------- ffmpeg 编码

def ffmpeg_encode(pcm_bytes, flac_path, extra, args_in):
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args_in + \
        ["-c:a", "flac"] + extra + [flac_path]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg encode failed: {r.stderr.strip()}")
    return open(flac_path, "rb").read()


def write_raw(path, samples, fmt):
    code = {"s16le": "<%dh", "s32le": "<%di"}[fmt]
    open(path, "wb").write(struct.pack(code % len(samples), *samples))


def find_flac():
    """libFLAC 官方 flac CLI（用于编码非 8 倍数位深——ffmpeg 不支持）。"""
    env = os.environ.get("FLAC_BIN")
    if env and os.path.exists(env):
        return env
    for base in (ROOT, os.path.dirname(ROOT)):
        local = os.path.join(
            base, "_ffmpeg", "_dl", "flac-win", "flac-1.5.0-win", "Win64",
            "flac.exe")
        if os.path.exists(local):
            return local
    return "flac"  # CI / Linux


def write_wav_ext(path, samples, valid_bits):
    """写 WAVE_FORMAT_EXTENSIBLE 单声道 WAV（valid_bits 可为 4..32 非整字节）。"""
    container = (valid_bits + 7) // 8
    shift = container * 8 - valid_bits
    data = bytearray()
    for v in samples:
        # 样本按高位对齐放进容器（WAV 约定，与我们的 wav_encode 一致）
        data += ((v << shift) & ((1 << (container * 8)) - 1)).to_bytes(
            container, "little", signed=False)
    sub = bytes.fromhex("0100000000001000800000aa00389b71")
    fmt = struct.pack("<HHIIHH", 0xFFFE, 1, 44100, 44100 * container,
                      container, container * 8)
    fmt += struct.pack("<HHI", 22, valid_bits, 0) + sub
    hdr = b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(data)) + \
        b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + \
        b"data" + struct.pack("<I", len(data))
    open(path, "wb").write(hdr + data)


def flac_encode_wav(flac_bin, wav_path, flac_path):
    r = subprocess.run([flac_bin, "-s", "-f", "-o", flac_path, wav_path],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if r.returncode != 0:
        raise RuntimeError(f"flac encode failed: {r.stderr.strip()}")
    return open(flac_path, "rb").read()


# ---------------------------------------------------------------- 用例集

def build():
    os.makedirs(CORPUS, exist_ok=True)
    cases = []

    def add(name, flac_bytes, kind="decode", note=""):
        path = os.path.join(CORPUS, name + ".flac")
        open(path, "wb").write(flac_bytes)
        cases.append({"name": name, "kind": kind, "note": note})

    # ===== A. ffmpeg 编码组合 =====
    # (标签, 信号, 采样率, 声道, bps, 额外参数, 原始格式)
    enc = []
    for nframes, dur in ((2000, "1帧"), (20000, "多帧")):
        n = nframes
        enc.append((f"sine16_{n}", sig_sine(n), 44100, 1, 16, [], "s16le"))
        enc.append((f"noise16_{n}", sig_noise(n, seed=7), 44100, 1, 16, [], "s16le"))
        enc.append((f"even16_{n}", sig_even(n), 44100, 1, 16, [], "s16le"))
        enc.append((f"scale4_16_{n}", sig_scale4(n), 44100, 1, 16, [], "s16le"))
        enc.append((f"silence16_{n}", sig_silence(n), 44100, 1, 16, [], "s16le"))
        enc.append((f"ramp16_{n}", sig_ramp(n), 44100, 1, 16, [], "s16le"))
        enc.append((f"step16_{n}", sig_step(n), 44100, 1, 16, [], "s16le"))
    _ = dur
    # 采样率扫描（帧头采样率码表）
    for rate in (8000, 88200, 192000, 48000):
        enc.append((f"sine16_r{rate}", sig_sine(3000, rate=rate), rate, 1, 16, [], "s16le"))
    # 声道数（原有 2/6 用例保留）
    for ch in (2, 6):
        sig = []
        for c in range(ch):
            sig.extend(sig_sine(3000, freq=220.0 * (c + 1)))
        inter = [0] * (3000 * ch)
        for c in range(ch):
            for i in range(3000):
                inter[i * ch + c] = sig[c * 3000 + i]
        enc.append((f"stereo_ch{ch}_16", inter, 44100, ch, 16, [], "s16le"))
    # 补齐声明范围 1–8 中的其余声道数
    for ch in (3, 4, 5, 7, 8):
        inter = []
        for i in range(3000):
            for c in range(ch):
                inter.append(int(8000 * __import__("math").sin(
                    2 * 3.141592653589793 * (220.0 * (c + 1)) * i / 44100)))
        enc.append((f"channels_ch{ch}_16", inter, 44100, ch, 16, [], "s16le"))
    # 立体声去相关模式
    l = sig_sine(4000, freq=440.0)
    r = sig_sine(4000, freq=1337.0, amp=20000)
    inter2 = []
    for i in range(4000):
        inter2 += [l[i], r[i]]
    for mode in ("indep", "left_side", "right_side", "mid_side"):
        enc.append((f"chmode_{mode}", inter2, 44100, 2, 16,
                    ["-ch_mode", mode], "s16le"))
    # 编码器路径：verbatim / fixed / LPC(levinson) + 分区序
    sig = sig_ramp(6000)
    for lpc in ("none", "fixed", "levinson"):
        enc.append((f"lpc_{lpc}", sig, 44100, 1, 16,
                    ["-lpc_type", lpc], "s16le"))
    for lo, hi in (("0", "0"), ("0", "2")):
        enc.append((f"porder_{lo}{hi}", sig, 44100, 1, 16,
                    ["-lpc_type", "fixed", "-min_partition_order", lo,
                     "-max_partition_order", hi], "s16le"))
    for prec in ("4", "9", "15"):
        enc.append((f"lpcprec_{prec}", sig_noise(6000, seed=3), 44100, 1, 16,
                    ["-lpc_type", "levinson", "-lpc_coeff_precision", prec],
                    "s16le"))
    for om in ("estimation", "2level", "search"):
        enc.append((f"predorder_{om}", sig, 44100, 1, 16,
                    ["-lpc_type", "fixed", "-prediction_order_method", om],
                    "s16le"))
    # 24 / 32 位
    for bps in (24, 32):
        s32 = [v << (32 - 16) for v in sig_noise(5000, seed=5)]
        enc.append((f"noise_bps{bps}", s32, 44100, 1, bps,
                    ["-bits_per_raw_sample", str(bps), "-strict", "-2"],
                    "s32le"))
        s32s = [v << (32 - 16) for v in sig_sine(5000)]
        enc.append((f"sine_bps{bps}", s32s, 48000, 2 if bps == 24 else 1, bps,
                    ["-bits_per_raw_sample", str(bps), "-strict", "-2"],
                    "s32le"))
    # 32 位立体声 mid/side（side 33 位路径）
    l32 = [v << 16 for v in sig_sine(5000, freq=440.0)]
    r32 = [v << 16 for v in sig_sine(5000, freq=999.0, amp=30000)]
    inter32 = []
    for i in range(5000):
        inter32 += [l32[i], r32[i]]
    enc.append((("bps32_midside"), inter32, 48000, 2, 32,
                ["-bits_per_raw_sample", "32", "-strict", "-2", "-ch_mode",
                 "mid_side"], "s32le"))

    for tag, pcm, rate, ch, bps, extra, fmt in enc:
        raw_path = os.path.join(CORPUS, f"_{tag}.raw")
        write_raw(raw_path, pcm, fmt)
        args_in = ["-f", fmt, "-ar", str(rate), "-ac", str(ch), "-i", raw_path]
        data = ffmpeg_encode(raw_path, os.path.join(CORPUS, tag + ".flac"),
                             extra, args_in)
        os.remove(raw_path)
        add(tag, data, note="ffmpeg 编码")

    # ===== A2. 非 8 倍数位深：libFLAC 编码（ffmpeg 会把 12/20 位静默退回 24 位）=====
    flac_bin = find_flac()
    print("flac:", flac_bin)
    for bps in (12, 20):
        for tag_sig, sig in (
            ("sine", sig_sine(3000, bps=bps, freq=523.25)),
            ("noise", sig_noise(3000, bps=bps, seed=bps)),
        ):
            tag = f"{tag_sig}_bps{bps}"
            wav_path = os.path.join(CORPUS, f"_{tag}.wav")
            write_wav_ext(wav_path, sig, bps)
            data = flac_encode_wav(flac_bin, wav_path,
                                   os.path.join(CORPUS, tag + ".flac"))
            os.remove(wav_path)
            add(tag, data, note=f"libFLAC 编码 {bps} 位")

    # 带 VORBIS_COMMENT 元数据块的真实文件（解码路径须越过该块）
    raw_path = os.path.join(CORPUS, "_with_meta.raw")
    write_raw(raw_path, sig_sine(3000), "s16le")
    data = ffmpeg_encode(
        raw_path, os.path.join(CORPUS, "with_meta.flac"),
        ["-metadata", "title=MoonBit测试", "-metadata", "artist=A=B"],
        ["-f", "s16le", "-ar", "44100", "-ac", "1", "-i", raw_path])
    os.remove(raw_path)
    add("with_meta", data, note="ffmpeg 编码 + VORBIS_COMMENT 块")

    # ===== B. 手造帧（覆盖编码器不产出的路径）=====
    # B1. rice 转义（param=15 -> 5 位原码位宽）
    n, bps = 64, 16
    small = [((i * 37 + 11) % 4001) - 2000 for i in range(n)]
    sf = sub_fixed(small, bps, 1, 0, escape_raw_bits=12)
    add("hand_escape_rice",
        make_flac([pack_frame(frame_header(n, 44100, 0, bps, 0), sf)],
                  n, 44100, 1, bps, n), note="手造 rice 转义")

    # B2. 采样率扩展码 12/13/14
    smp = sig_sine(64)
    for tag, sr_extra, sr in (
        ("sr12", (11, 8, 12), 11000),
        ("sr13", (12345, 16, 13), 12345),
        ("sr14", (4411, 16, 14), 44110),
    ):
        sf = sub_verbatim(smp, 16)
        hdr = frame_header(64, sr, 0, 16, 0, sr_extra=sr_extra)
        add(f"hand_{tag}",
            make_flac([pack_frame(hdr, sf)], 64, sr, 1, 16, 64),
            note=f"采样率扩展码 {tag}")

    # B3. 变长帧号 / 可变块长
    for tag, number, variable in (
        ("utf8_2byte", 200, False),
        ("utf8_3byte", 70000, False),
        ("variable_blk", 12345, True),
    ):
        sf = sub_verbatim(smp, 16)
        hdr = frame_header(64, 44100, 0, 16, number, variable=variable)
        add(f"hand_{tag}",
            make_flac([pack_frame(hdr, sf)], 64, 44100, 1, 16, 64),
            note=tag)

    # B4. 130 帧串联（帧号进 2 字节区间 + 多帧循环 + total_samples 截断逻辑）
    frames = []
    for i in range(130):
        hdr = frame_header(64, 44100, 0, 16, i)
        frames.append(pack_frame(hdr, sub_constant(i - 65, 16)))
    add("hand_130frames",
        make_flac(frames, 64, 44100, 1, 16, 64 * 130),
        note="130 帧常数子帧链（帧号跨 1 字节边界）")

    # B5. 块长码扫描（表码 + 8/16 位扩展字段）
    for bs in (64, 192, 256, 512, 1000, 4608):
        s2 = [((i * 91 + 7) % 60001) - 30000 for i in range(bs)]
        hdr = frame_header(bs, 44100, 0, 16, 0)
        add(f"hand_bs{bs}",
            make_flac([pack_frame(hdr, sub_verbatim(s2, 16))],
                      bs, 44100, 1, 16, bs),
            note=f"block_size={bs}")

    # B6. wasted bits（constant / verbatim，k=1..3）
    for k, tv in ((1, -32000), (2, 24000), (3, 123448)):
        v = tv & ~((1 << k) - 1)
        sf = sub_constant_wasted(v, 16, k)
        hdr = frame_header(64, 44100, 0, 16, 0)
        add(f"hand_wconst_k{k}",
            make_flac([pack_frame(hdr, sf)], 64, 44100, 1, 16, 64),
            note=f"constant wasted k={k}")
        # verbatim + wasted
        w = W()
        w.w(0, 1); w.w(0b000001, 6); w.w(1, 1)
        w.w(0, k - 1); w.w(1, 1)
        eff = 16 - k
        for _ in range(64):
            w.w((v >> k) & ((1 << eff) - 1), eff)
        w.align()
        add(f"hand_wverb_k{k}",
            make_flac([pack_frame(hdr, bytes(w.out))], 64, 44100, 1, 16, 64),
            note=f"verbatim wasted k={k}")

    # B7. FIXED 阶 0..4 + 转义方法=1（Rice2 5 位参数）
    for order in range(5):
        s2 = sig_noise(64, seed=order + 11)
        sf = sub_fixed(s2, 16, order, 5)
        hdr = frame_header(64, 44100, 0, 16, 0)
        add(f"hand_fixed_o{order}",
            make_flac([pack_frame(hdr, sf)], 64, 44100, 1, 16, 64),
            note=f"FIXED order={order}")
    s2 = [((i * 61 + 3) % 4001) - 2000 for i in range(64)]
    sf = sub_fixed(s2, 16, 1, 8, entropy_method=1, method_param_len=5)
    hdr = frame_header(64, 44100, 0, 16, 0)
    add("hand_rice2",
        make_flac([pack_frame(hdr, sf)], 64, 44100, 1, 16, 64),
        note="method=1 Rice2 5位参数")

    # B7.5. 4 位深（无任何参考编码器支持；纯手造 constant/verbatim）
    s4 = [((i * 5 + 3) % 16) - 8 for i in range(64)]  # -8..7
    hdr = frame_header(64, 44100, 0, 4, 0)
    add("hand_bps4_verbatim",
        make_flac([pack_frame(hdr, sub_verbatim(s4, 4))], 64, 44100, 1, 4, 64),
        note="4 位手造 verbatim")
    hdr4 = frame_header(64, 44100, 0, 4, 1)
    add("hand_bps4_constant",
        make_flac([pack_frame(hdr, sub_constant(-3, 4))], 64, 44100, 1, 4, 64),
        note="4 位手造 constant")

    # B8. 全元数据块类型链：APPLICATION/SEEKTABLE/VORBIS_COMMENT/PICTURE/PADDING
    #     （解码路径须逐块越过；读取内容由单元测试覆盖）
    app = bytes([0x4D, 0x4F, 0x4F, 0x4E, 1, 2])  # MOON + 数据
    st_w = W()
    st_w.w(0, 64); st_w.w(0, 64); st_w.w(0, 16)  # 单占位点
    seektable = bytes(st_w.out)
    vc_w = W()
    def le32(w, v):
        w.w(v & 0xFF, 8); w.w((v >> 8) & 0xFF, 8)
        w.w((v >> 16) & 0xFF, 8); w.w((v >> 24) & 0xFF, 8)
    le32(vc_w, 3)
    for b in b"fbm":
        vc_w.w(b, 8)
    le32(vc_w, 1)
    le32(vc_w, 11)
    for b in b"TITLE=cover":
        vc_w.w(b, 8)
    vcomment = bytes(vc_w.out)
    pic_w = W()
    for v in (3, 9):
        pic_w.w(v, 32)
    for b in b"image/png":
        pic_w.w(b, 8)
    pic_w.w(0, 32)  # 描述空
    for v in (1, 1, 24, 0, 3):
        pic_w.w(v, 32)
    for b in (0x89, 0x50, 0x4E):
        pic_w.w(b, 8)
    picture = bytes(pic_w.out)
    pad = bytes([0, 0, 0])
    si_body = streaminfo(64, 44100, 1, 16, 64)
    hdr = frame_header(64, 44100, 0, 16, 0)
    frame = pack_frame(hdr, sub_constant(42, 16))
    out = bytearray(b"fLaC")
    out += bytes([0x00]) + (34).to_bytes(3, "big") + si_body
    for last, typ, payload in ((0, 2, app), (0, 3, seektable), (0, 4, vcomment),
                               (0, 6, picture), (1, 1, pad)):
        out += bytes([(last << 7) | typ]) + len(payload).to_bytes(3, "big") + payload
    out += frame
    add("hand_allblocks", bytes(out), note="手造：全部元数据块类型链")

    # ===== C. 负例（必须解码失败）=====
    base = open(os.path.join(CORPUS, "hand_bs64.flac"), "rb").read()
    add("neg_notflac", b"RIFF\x00\x00\x00\x00WAVEjunk", kind="negative",
        note="非 FLAC 魔数")
    add("neg_empty", b"", kind="negative", note="空文件")
    # 截断：多帧流砍掉 40%
    multi = open(os.path.join(CORPUS, "sine16_20000.flac"), "rb").read()
    add("neg_truncated", multi[: int(len(multi) * 0.6)], kind="negative",
        note="中途截断（total_samples 已知 -> Truncated）")
    # CRC-16 破坏：翻转首帧 verbatim 数据区一个字节（结构保持）
    bad = bytearray(base)
    bad[len(bad) // 2] ^= 0xFF
    add("neg_crc16", bytes(bad), kind="negative", note="帧数据字节翻转 -> CRC-16")
    # CRC-8 破坏：翻转帧头中部字节
    bad2 = bytearray(open(os.path.join(CORPUS, "hand_utf8_2byte.flac"), "rb").read())
    bad2[42 + 6] ^= 0x0F  # 帧头内（帧从 46 字节起；头部第 6 字节）
    add("neg_crc8", bytes(bad2), kind="negative", note="帧头字节翻转")
    # MD5 篡改：把 STREAMINFO 的 MD5 改一位 -> 解码尾部校验必须报错
    md5_bad = bytearray(open(os.path.join(CORPUS, "sine16_2000.flac"), "rb").read())
    assert md5_bad[26:42] != bytes(16), "该用例应带非零 MD5"
    md5_bad[41] ^= 0xFF
    add("neg_md5", bytes(md5_bad), kind="negative", note="STREAMINFO MD5 篡改")

    manifest = os.path.join(CORPUS, "manifest.json")
    with open(manifest, "w", encoding="utf-8") as f:
        json.dump(cases, f, ensure_ascii=False, indent=1)
    n_decode = sum(1 for c in cases if c["kind"] == "decode")
    print(f"语料生成完成：{n_decode} 个正例，{len(cases) - n_decode} 个负例 -> {CORPUS}")


if __name__ == "__main__":
    for a in sys.argv[1:]:
        if a == "--ffmpeg" and len(sys.argv) > sys.argv.index(a) + 1:
            os.environ["FLAC_FFMPEG"] = sys.argv[sys.argv.index(a) + 1]
    FFMPEG = find_ffmpeg()
    print("ffmpeg:", FFMPEG)
    build()
