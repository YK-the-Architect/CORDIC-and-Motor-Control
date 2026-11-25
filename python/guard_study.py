#!/usr/bin/env python3
"""python/guard_study.py : the fewest guard bits G and iterations N that still meet the accuracy
spec, at W = 16, using the bit-exact model (python/cordic_model.py).

The spec is the one tb/tb_datatypes.sv checks: worst error at most 2 LSB for rotation (x, y),
vectoring (magnitude and angle, |v| >= 0.25), multiply and divide, and rotation bias (mean error)
within 0.1 LSB. Same input ranges as tb_datatypes, more vectors. Two answers: for all four
operations, and for rotation and vectoring only (all that motor control uses).

  python3 python/guard_study.py [--vectors 200000] [--json out.json] [--png out.png]
  python3 python/guard_study.py --exhaustive 3,4,5    every vector in the vectoring spec range
                                                     (|x|, |y| <= 0.7, |v| >= 0.25), N = 16
"""
import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cordic_model import Cordic   # noqa: E402

W = 16
NS = list(range(12, 21))
GS = list(range(0, 8))
LIMIT, BIAS = 2.0, 0.1


def inputs(nvec, seed=271):
    """Integer inputs for the four operations, same ranges as tb_datatypes (quantized like q())."""
    rng = np.random.default_rng(seed)
    qxy, qzl, turn = float(1 << (W - 2)), float(1 << (W - 1)), float(1 << W)

    def q(v, scale):
        s = v * scale
        c = np.trunc(s + np.where(s >= 0, 0.5, -0.5)).astype(np.int64)
        return np.clip(c, -(1 << (W - 1)), (1 << (W - 1)) - 1)

    rot = dict(x=q(rng.uniform(-0.7, 0.7, nvec), qxy), y=q(rng.uniform(-0.7, 0.7, nvec), qxy),
               z=rng.integers(-(1 << (W - 1)), 1 << (W - 1), nvec))
    vx, vy = q(rng.uniform(-0.7, 0.7, 3 * nvec), qxy), q(rng.uniform(-0.7, 0.7, 3 * nvec), qxy)
    keep = np.hypot(vx / qxy, vy / qxy) >= 0.25
    vec = dict(x=vx[keep][:nvec], y=vy[keep][:nvec])
    m = nvec // 4
    mul = dict(x=q(rng.uniform(-1, 1, m), qxy), z=q(rng.uniform(-0.99, 0.99, m), qzl))
    dx = q(rng.uniform(0.5, 1.0, m), qxy)
    div = dict(x=dx, y=q(rng.uniform(-0.9, 0.9, m) * (dx / qxy), qxy))
    return rot, vec, mul, div, (qxy, qzl, turn)


def measure(e, data):
    """Worst error (LSB) of each output, and the rotation bias, for one configuration."""
    rot, vec, mul, div, (qxy, qzl, turn) = data
    out = {}
    xo, yo, _, _ = e.run_np(rot["x"], rot["y"], rot["z"], 0, 0)
    x0, y0, th = rot["x"] / qxy, rot["y"] / qxy, rot["z"] * 2 * math.pi / turn
    ex, ey = xo - (x0 * np.cos(th) - y0 * np.sin(th)) * qxy, yo - (x0 * np.sin(th) + y0 * np.cos(th)) * qxy
    out["rotation"] = float(max(np.abs(ex).max(), np.abs(ey).max()))
    out["bias"] = float(max(abs(ex.mean()), abs(ey.mean())))
    xo, _, zo, _ = e.run_np(vec["x"], vec["y"], 0, 0, 1)
    x0, y0 = vec["x"] / qxy, vec["y"] / qxy
    em = xo - np.hypot(x0, y0) * qxy
    ea = (zo - np.arctan2(y0, x0) / (2 * math.pi) * turn + turn / 2) % turn - turn / 2
    out["magnitude"] = float(np.abs(em).max())
    out["angle"] = float(np.abs(ea).max())
    _, yo, _, _ = e.run_np(mul["x"], 0, mul["z"], 1, 0)
    out["multiply"] = float(np.abs(yo - (mul["x"] / qxy) * (mul["z"] / qzl) * qxy).max())
    _, _, zo, _ = e.run_np(div["x"], div["y"], 0, 1, 1)
    out["divide"] = float(np.abs(zo - (div["y"] / div["x"]) * qzl).max())
    out["worst"] = max(out[k] for k in ("rotation", "magnitude", "angle", "multiply", "divide"))
    out["worst_circ"] = max(out[k] for k in ("rotation", "magnitude", "angle"))
    out["pass"] = out["worst"] <= LIMIT and out["bias"] <= BIAS
    out["pass_circ"] = out["worst_circ"] <= LIMIT and out["bias"] <= BIAS
    return out


def vectoring_exhaustive(n, g):
    """Worst magnitude and angle error over every input pair in the vectoring spec range."""
    e = Cordic(W, n, g)
    qxy, turn = float(1 << (W - 2)), float(1 << W)
    lim = int(0.7 * qxy)
    xs = np.arange(-lim, lim + 1, dtype=np.int64)
    wm = wa = 0.0
    count = 0
    for k in range(0, len(xs), 64):
        X, Y = np.meshgrid(xs[k:k + 64], xs, indexing="ij")
        X, Y = X.ravel(), Y.ravel()
        x0, y0 = X / qxy, Y / qxy
        keep = np.hypot(x0, y0) >= 0.25
        X, Y, x0, y0 = X[keep], Y[keep], x0[keep], y0[keep]
        xo, _, zo, _ = e.run_np(X, Y, 0, 0, 1)
        wm = max(wm, float(np.abs(xo - np.hypot(x0, y0) * qxy).max()))
        wa = max(wa, float(np.abs((zo - np.arctan2(y0, x0) / (2 * math.pi) * turn + turn / 2) % turn - turn / 2).max()))
        count += len(X)
    return count, wm, wa


def cost(n, g):
    """Relative size of the pipeline: N iteration stages, each with 3 lanes of W + 2 + G bits."""
    return n * 3 * (W + 2 + g)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=int, default=200000)
    ap.add_argument("--json")
    ap.add_argument("--png")
    ap.add_argument("--exhaustive", default="", help="comma-separated G values: exhaustive vectoring")
    ap.add_argument("--n", type=int, default=16, help="iterations for --exhaustive")
    ap.add_argument("--exh", help="JSON from --exhaustive to mark on the chart")
    ap.add_argument("--font", type=float, default=10, help="chart font size (larger for slides)")
    a = ap.parse_args()
    if a.exhaustive:
        pts = []
        for g in [int(v) for v in a.exhaustive.split(",")]:
            cnt, wm, wa = vectoring_exhaustive(a.n, g)
            pts.append(dict(N=a.n, G=g, vectors=cnt, magnitude=wm, angle=wa))
            print(f"N = {a.n}, G = {g}: {cnt:,} vectors, worst magnitude {wm:.2f} LSB, worst angle {wa:.2f} LSB  "
                  f"{'meets' if max(wm, wa) <= LIMIT else 'fails'}", flush=True)
        if a.json:
            json.dump(pts, open(a.json, "w"), indent=1)
        return
    data = inputs(a.vectors)
    res = {}
    for n in NS:
        for g in GS:
            r = measure(Cordic(W, n, g), data)
            res[(n, g)] = r
            print(f"N = {n:2d}, G = {g}: worst {r['worst']:6.2f} LSB (rot {r['rotation']:.2f}, |v| {r['magnitude']:.2f}, "
                  f"angle {r['angle']:.2f}, mul {r['multiply']:.2f}, div {r['divide']:.2f}), bias {r['bias']:.3f}  "
                  f"{'meets' if r['pass'] else 'fails'}", flush=True)

    dflt = Cordic(W, 16).G
    summary = {}
    for key, label in (("pass", "all four operations"), ("pass_circ", "rotation and vectoring only")):
        ok = [k for k, r in res.items() if r[key]]
        min_g16 = min((g for n, g in ok if n == 16), default=None)
        min_n = min((n for n, g in ok if g == dflt), default=None)
        best = min(ok, key=lambda k: (cost(*k), k)) if ok else None
        summary[key] = dict(min_G_at_N16=min_g16, min_N_at_default_G=min_n, smallest=best)
        print(f"\n{label}: at N = 16 the fewest guard bits that meet the spec is G = {min_g16} (default {dflt}); "
              f"with G = {dflt} the fewest iterations is N = {min_n}")
        if best:
            print(f"  smallest passing configuration (N x lane width): N = {best[0]}, G = {best[1]}, "
                  f"{100 * (cost(*best) / cost(16, dflt) - 1):+.0f}% lane bits against N = 16, G = {dflt}")

    if a.json:
        json.dump({"W": W, "vectors": a.vectors, "default_G": dflt, "summary": summary,
                   "grid": [dict(N=n, G=g, **r) for (n, g), r in sorted(res.items())]}, open(a.json, "w"), indent=1)
        print("wrote", a.json)
    if a.png:
        plot(res, dflt, a.png, json.load(open(a.exh)) if a.exh else [], a.font)


def plot(res, dflt, path, exh, font=10):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
    GRID, AXIS, BLUE, ORANGE = "#e1e0d9", "#c3c2b7", "#2a78d6", "#eb6834"
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": font, "text.color": INK,
                         "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED})
    fig, axs = plt.subplots(1, 2, figsize=(11 * font / 10, 4.2 * font / 10), facecolor=SURFACE)

    def style(ax, title, xlabel):
        ax.set_facecolor(SURFACE)
        ax.set_title(title, loc="left", fontsize="large", color=INK, pad=10)
        ax.set_xlabel(xlabel)
        ax.set_ylabel("worst error (LSB)")
        ax.set_yscale("log")
        ax.set_yticks([1, 2, 5, 10, 20])
        ax.set_yticklabels(["1", "2", "5", "10", "20"])
        ax.minorticks_off()
        ax.grid(axis="y", color=GRID, linewidth=1)
        ax.set_axisbelow(True)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        for s in ("left", "bottom"):
            ax.spines[s].set_color(AXIS)
        ax.tick_params(length=0)
        ax.axhline(LIMIT, color=INK2, linewidth=1, linestyle=(0, (4, 3)))
        ax.text(1.0, LIMIT * 1.08, "spec: 2 LSB", transform=ax.get_yaxis_transform(), color=INK2, fontsize="small",
                ha="right", va="bottom")

    def series(ax, xs, key_all, key_circ, mark_x, mark_label):
        ya = [res[k]["worst"] for k in key_all]
        yc = [res[k]["worst_circ"] for k in key_circ]
        ax.plot(xs, ya, color=BLUE, linewidth=2, marker="o", markersize=6, markeredgecolor=SURFACE,
                markeredgewidth=1.5, label="all four operations (divide is the worst)")
        ax.plot(xs, yc, color=ORANGE, linewidth=2, marker="o", markersize=6, markeredgecolor=SURFACE,
                markeredgewidth=1.5, label="rotation and vectoring (motor control)")
        ax.annotate("all four", (xs[-1], ya[-1]), textcoords="offset points", xytext=(6, 4), fontsize="small", color=INK2)
        ax.annotate("rotation, vectoring", (xs[-1], yc[-1]), textcoords="offset points", xytext=(6, -10),
                    fontsize="small", color=INK2)
        ax.axvline(mark_x, color=AXIS, linewidth=1, zorder=0)
        ax.text(mark_x, 0.98, " " + mark_label, transform=ax.get_xaxis_transform(), fontsize="small", color=INK2,
                va="top", ha="left")
        ax.set_xticks(xs)
        ax.set_xlim(xs[0] - 0.4, xs[-1] + 2.2)

    ax = axs[0]
    style(ax, "Guard bits G, with N = 16", "guard bits G")
    series(ax, GS, [(16, g) for g in GS], [(16, g) for g in GS], dflt, f"as built (G = {dflt})")
    pts = [p for p in exh if p["N"] == 16]
    if pts:   # every vector in the vectoring range, not a sample: the true worst case
        ax.plot([p["G"] for p in pts], [max(p["magnitude"], p["angle"]) for p in pts], linestyle="none",
                marker="o", markersize=9, markerfacecolor="none", markeredgecolor=ORANGE, markeredgewidth=1.8,
                label="vectoring, every vector (exhaustive)")
        for p in pts:
            ax.annotate(f"{max(p['magnitude'], p['angle']):.2f}", (p["G"], max(p["magnitude"], p["angle"])),
                        textcoords="offset points", xytext=(8, 2), fontsize="small", color=INK2)
    ax.legend(loc="upper right", frameon=False, fontsize="small", bbox_to_anchor=(1.0, 0.9))

    ax = axs[1]
    style(ax, f"Iterations N, with G = {dflt}", "iterations N")
    series(ax, NS, [(n, dflt) for n in NS], [(n, dflt) for n in NS], 16, "as built (N = 16)")
    fig.tight_layout(w_pad=3)
    fig.savefig(path, dpi=160, facecolor=SURFACE)
    print("wrote", path)


if __name__ == "__main__":
    main()
