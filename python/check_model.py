#!/usr/bin/env python3
"""python/check_model.py : compares the RTL results dumped by tb/tb_model_vectors.sv with the
bit-exact Python model (python/cordic_model.py).

  python3 python/check_model.py <vectors file> [<vectors file> ...]

Each file says its W, N and G on the first line. Line dumps are compared one operation at a
time; exhaustive dumps (EXH = 1) are compared as 256 block checksums per mode. Prints one PASS or
FAIL line per file and exits 1 if any file fails.
"""
import re
import sys
import os

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cordic_model import Cordic   # noqa: E402

MODES = {(0, 0): "rotation", (0, 1): "vectoring", (1, 0): "multiply", (1, 1): "divide"}


def check_lines(e, rows):
    a = np.array(rows, dtype=np.int64)
    bad, shown = 0, 0
    for cl in (0, 1):
        for rv in (0, 1):
            s = a[(a[:, 0] == cl) & (a[:, 1] == rv)]
            if len(s) == 0:
                continue
            xo, yo, zo, ov = e.run_np(s[:, 2], s[:, 3], s[:, 4], cl, rv)
            diff = (xo != s[:, 5]) | (yo != s[:, 6]) | (zo != s[:, 7]) | (ov.astype(np.int64) != s[:, 8])
            bad += int(diff.sum())
            for r in s[diff][:max(0, 5 - shown)]:
                m = e.run(*[int(v) for v in r[2:5]], cl, rv)
                print(f"  {MODES[(cl, rv)]} in ({r[2]}, {r[3]}, {r[4]}): RTL ({r[5]}, {r[6]}, {r[7]}, ovf {r[8]}), "
                      f"model ({m.x}, {m.y}, {m.z}, ovf {int(m.ovf)})")
                shown += 1
    return len(a), bad


def check_blocks(e, blocks):
    W = e.W
    total = 1 << (3 * W)
    bs = total // 256
    mask = (1 << W) - 1
    bad = 0
    chunk = min(total, 1 << 20)
    for (cl, rv), want in sorted(blocks.items()):
        got = np.zeros(256, dtype=np.uint64)
        for start in range(0, total, chunk):
            k = np.arange(start, start + chunk, dtype=np.int64)
            sx = lambda v: np.where(v >= (1 << (W - 1)), v - (1 << W), v)
            x, y, z = sx(k & mask), sx((k >> W) & mask), sx((k >> (2 * W)) & mask)
            xo, yo, zo, ov = e.run_np(x, y, z, cl, rv)
            out = ((xo & mask) | ((yo & mask) << W) | ((zo & mask) << (2 * W)) |
                   (ov.astype(np.int64) << (3 * W))).astype(np.uint64)
            prod = out * (k.astype(np.uint64) | np.uint64(1))       # wraps mod 2^64, as in the TB
            got[start // bs:(start + chunk) // bs] += prod.reshape(-1, bs).sum(axis=1, dtype=np.uint64)
        for b in range(256):
            if int(got[b]) != want.get(b, -1):
                if bad < 5:
                    print(f"  {MODES[(cl, rv)]} block {b}: RTL {want.get(b, -1):016x}, model {int(got[b]):016x}")
                bad += 1
    return 4 * total, bad


def main(files):
    ok_all = True
    for f in files:
        lines = open(f).read().split("\n")
        hdr = dict(re.findall(r"(\w+) (\d+)", lines[0]))
        e = Cordic(int(hdr["W"]), int(hdr["N"]), int(hdr["G"]))
        rows, blocks = [], {}
        for ln in lines[1:]:
            p = ln.split()
            if not p:
                continue
            if p[0] == "B":
                blocks.setdefault((int(p[1]), int(p[2])), {})[int(p[3])] = int(p[4], 16)
            else:
                rows.append([int(v) for v in p])
        if blocks:
            n, bad = check_blocks(e, blocks)
            what = f"{n:,} operations (every input, all 4 modes), 1,024 checksums"
        else:
            n, bad = check_lines(e, rows)
            what = f"{n:,} operations"
        engine = "cordic_pipe" if hdr.get("PIPE") == "1" else "cordic_ss"
        ok = bad == 0 and n > 0
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} W = {e.W}, N = {e.N}, G = {e.G} ({engine}): {what}, "
              f"{bad} different from the model")
    return 0 if ok_all else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
