#!/usr/bin/env python3
"""syn/balance.py : where to put R register ranks in cordic_pipe.

Reads the block delays from an OpenSTA run of the fully pipelined engine (every cut point
registered, so each stage is exactly one block), then for each R finds the R cut points that
make the slowest stage as fast as possible (exact search, dynamic programming). Writes the
cut points as JSON for run_ppa.py --points.

  python3 syn/balance.py <full pipeline sta.log> <out.json> [R ...]
"""
import json, re, sys

N = 16                                   # iterations
NB = N + 5                               # blocks: input, N iterations, carry-save, add, round, saturate
CQ = 0.12                                # flop clock-to-Q, about what the reports show for DFF_X1
IO_SHARE = 0.25                          # same input budget as the SDC


def block_delays(log):
    s = open(log).read()
    tmin = float(re.search(r"TMIN ([\d.]+)", s).group(1))
    sec = re.search(r"=== endpoints at TMIN\n(.*?)\n=== end", s, re.S).group(1)
    arr = {}
    for m in re.finditer(r"^(\S+)/D \(\S+\)\s+([\d.]+)\s+([\d.]+)", sec, re.M):
        inst, a = m.group(1), float(m.group(3))
        g = re.match(r"g_cut_(\d+)_u_cut_", inst)
        if g: b = int(g.group(1))
        elif inst.startswith("cs_q"): b = N + 1
        elif inst.startswith("pr_q"): b = N + 2
        elif inst.startswith("rn_q"): b = N + 3
        elif inst.startswith(("m_q", "s_q")): b = N + 4
        else: continue
        arr[b] = max(arr.get(b, 0.0), a)
    d = [0.0] * NB
    for b in range(NB):
        launch = IO_SHARE * tmin if b == 0 else CQ   # the input stage starts at a port
        d[b] = round(arr[b] - launch, 4)
    return d


def best_cuts(d, R, in_delay):
    """R cut points (0 to NB - 2, cut j sits after block j) that minimize the slowest stage."""
    INF = float("inf")
    def seg(a, b):                                    # blocks a..b in one stage
        return sum(d[a:b + 1]) + (in_delay if a == 0 else CQ)
    if R == 0:
        return [], seg(0, NB - 1)
    # f[r][j]: best max stage delay for blocks 0..j with r cuts, the last one after block j
    f = [[INF] * NB for _ in range(R + 1)]
    back = [[-1] * NB for _ in range(R + 1)]
    for j in range(NB - 1):
        f[1][j] = seg(0, j) if R >= 1 else INF
    for r in range(2, R + 1):
        for j in range(NB - 1):
            for i in range(j):
                v = max(f[r - 1][i], seg(i + 1, j))
                if v < f[r][j]:
                    f[r][j], back[r][j] = v, i
    if R == 0:
        return [], seg(0, NB - 1)
    best, last = INF, -1
    for j in range(NB - 1):
        v = max(f[R][j], seg(j + 1, NB - 1))
        if v < best:
            best, last = v, j
    cuts, r, j = [], R, last
    while r >= 1:
        cuts.append(j)
        j = back[r][j]
        r -= 1
    return sorted(cuts), best


def main():
    log, out = sys.argv[1], sys.argv[2]
    Rs = [int(x) for x in sys.argv[3:]] or [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20]
    d = block_delays(log)
    names = ["input"] + [f"iter{i}" for i in range(N)] + ["csa", "add", "round", "sat"]
    print("block delays (ns):", ", ".join(f"{n} {v:.3f}" for n, v in zip(names, d)))
    points = []
    for R in Rs:
        t = 1.0
        for _ in range(4):                    # the input budget depends on the period
            cuts, worst = best_cuts(d, R, IO_SHARE * t + 0.02)
            t = worst + 0.03 + 0.05           # setup and clock uncertainty
        points.append([f"pipe_r{R:02d}", cuts])
        print(f"R = {R:2d}: cuts {cuts}  estimated period {t:.3f} ns")
    json.dump(points, open(out, "w"))


if __name__ == "__main__":
    main()
