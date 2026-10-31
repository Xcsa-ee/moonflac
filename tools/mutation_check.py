"""变异验证：把关键判据逐个改错，断言单元测试一定会变红。

做法：把仓库复制到临时目录 → 对源码做一处等价于"写错"的替换 → 跑 `moon test --target wasm-gc`
→ 期望**非零退出**（测试抓到错误）→ 还原文件。若有任何一处变异后测试仍然全绿，
说明该判据缺少判别性用例，本脚本以退出码 1 报告"存活变异"。

用法：
    python tools/mutation_check.py [--target wasm-gc] [--keep]

    --keep   保留临时目录，便于手工复查
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (判据名称, 文件, 原文, 改成, 说明)
MUTATIONS = [
    (
        "CRC-16 覆盖起点",
        "flac.mbt",
        "crc16_range(br.data, h.start_byte, crc_pos)",
        "crc16_range(br.data, h.start_byte + 1, crc_pos)",
        "从帧起始后一字节开始算 CRC-16",
    ),
    (
        "mid/side 补回最低位",
        "flac.mbt",
        "(temp[0][i] << 1) | (side & 1L)",
        "(temp[0][i] << 1)",
        "丢掉 side 的最低位，mid2 少补 1",
    ),
    (
        "wasted bits 左移",
        "subframe.mbt",
        "xs[i] = xs[i] << k",
        "xs[i] = xs[i]",
        "不按 wasted bits 左移还原",
    ),
    (
        "LPC 预测右移按 s(5)",
        "subframe.mbt",
        "let shift = if shift_field >= 16 { shift_field - 32 } else { shift_field }",
        "let shift = shift_field",
        "把 s(5) 当无符号处理，负位移丢失",
    ),
    (
        "Rice unary 方向",
        "residual.mbt",
        "while br.read_bit() == 0 {",
        "while br.read_bit() == 1 {",
        "商按「q 个 1 + 0」解析，方向反了",
    ),
    (
        "块长上限 65535",
        "frame.mbt",
        "if block_size < 1 || block_size > 65535 {",
        "if block_size < 1 || block_size > 65536 {",
        "放宽到允许 65536（RFC 禁止）",
    ),
]

IGNORE = shutil.ignore_patterns(".git", "_build", ".mooncakes", "__pycache__", "target")


def run_tests(root, target):
    r = subprocess.run(
        ["moon", "test", "--target", target],
        cwd=root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="wasm-gc")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="moonflac_mut_")
    work = os.path.join(tmp, "repo")
    print(f"复制仓库到 {work} ...")
    shutil.copytree(ROOT, work, ignore=IGNORE)

    print("基线：未变异时应全绿 ...")
    code, out = run_tests(work, args.target)
    if code != 0:
        print("基线就失败了，先修好再跑变异检查：")
        print(out[-2000:])
        return 2

    survived = []
    t0 = time.time()
    for name, rel, old, new, why in MUTATIONS:
        path = os.path.join(work, rel)
        with open(path, encoding="utf-8") as f:
            original = f.read()
        if old not in original:
            print(f"[跳过] {name}: 在 {rel} 里找不到目标片段（代码已变化，请更新 MUTATIONS）")
            survived.append(name + "（片段未找到）")
            continue
        mutated = original.replace(old, new)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(mutated)
        started = time.time()
        code, out = run_tests(work, args.target)
        elapsed = time.time() - started
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(original)
        caught = code != 0
        tail = " ".join(
            line.strip()
            for line in out.splitlines()
            if "Total tests" in line or "failed" in line.lower()
        )[-120:]
        print(f"[{'抓到' if caught else '存活'}] {name}（{elapsed:.1f}s）：{why} | {tail}")
        if not caught:
            survived.append(name)

    total = time.time() - t0
    print(f"\n结果：{len(MUTATIONS) - len(survived)}/{len(MUTATIONS)} 变异被抓到，用时 {total:.1f}s")
    if survived:
        print("存活变异（说明缺少判别性用例）：" + "、".join(survived))
    if args.keep:
        print(f"临时目录保留在 {work}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
