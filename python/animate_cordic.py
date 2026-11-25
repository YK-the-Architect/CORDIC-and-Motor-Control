#!/usr/bin/env python3
"""python/animate_cordic.py : an animation of one CORDIC operation, step by step, from the engine's
exact lane values (python/cordic_model.py gives the same bits as the RTL).

  python3 python/animate_cordic.py                         rotate (0.8, 0.2) by 125 deg
  python3 python/animate_cordic.py rotate 0.8 0.2 125
  python3 python/animate_cordic.py vector -0.5 0.6
  options: --out <file.gif> (default docs/cordic_<mode>.gif; a .png of the last frame is saved too)

Left: the vector after each iteration, drawn with the gain K taken out so its length stays put.
Right: the angle still to go (rotation) or the y still left (vectoring), which halves about every
iteration: one more bit of the answer per clock.
"""
import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cordic_model import Cordic   # noqa: E402

SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, BLUE, ORANGE = "#e1e0d9", "#c3c2b7", "#2a78d6", "#eb6834"

args = [a for a in sys.argv[1:]]
out = None
if "--out" in args:
    k = args.index("--out")
    out = args[k + 1]
    del args[k:k + 2]
mode = args[0] if args else "rotate"
nums = [float(a) for a in args[1:]]
if mode == "rotate":
    x0, y0, deg = (nums + [0.8, 0.2, 125.0][len(nums):])[:3]
elif mode == "vector":
    x0, y0 = (nums + [-0.5, 0.6][len(nums):])[:2]
    deg = 0.0
else:
    sys.exit(__doc__)
here = os.path.dirname(os.path.abspath(__file__))
out = out or os.path.join(here, "..", "docs", f"cordic_{mode}.gif")

e = Cordic(16, 16)
W, G = e.W, e.G
K = e.C / 2.0 ** e.F                                  # the hardware's 1/gain
lane_xy = 2.0 ** (W - 2 + G)                          # lane units per 1.0 (x, y)
lane_turn = 2.0 ** (W + G)                            # lane units per 360 deg (z)
xi, yi, zi = e.q_xy(x0), e.q_xy(y0), e.deg2z(deg)
trace = []
res = e.run(xi, yi, zi, 0, 1 if mode == "vector" else 0, trace=trace)


def zdeg(z):
    d = z / lane_turn * 360.0
    return (d + 180.0) % 360.0 - 180.0


# frames: (title, x, y, residual) with x, y gain-corrected reals
frames = [("input", e.xy2real(xi), e.xy2real(yi), deg if mode == "rotate" else e.xy2real(yi))]
first = trace[0]
folded = (first[1] != xi << G) or (first[2] != yi << G)
if folded:
    frames.append(("fold: rotate by 180 deg first, so the rest is within +-90 deg",
                   first[1] / lane_xy, first[2] / lane_xy, zdeg(first[3]) if mode == "rotate" else first[2] / lane_xy))
gain = 1.0
for i, x, y, z in trace[1:]:
    gain *= math.sqrt(1 + 4.0 ** -i)
    step = math.degrees(math.atan(2.0 ** -i))
    frames.append((f"iteration {i}: turn by {step:.4f} deg ({'2^-' + str(i)} shifts)",
                   x * K / lane_xy, y * K / lane_xy, zdeg(z) if mode == "rotate" else y * K / lane_xy))
frames.append(("result after ×K and rounding: " + (f"({e.xy2real(res.x):+.5f}, {e.xy2real(res.y):+.5f})" if mode == "rotate"
               else f"|v| = {e.xy2real(res.x):.5f}, angle {e.z2deg(res.z):+.3f} deg"),
               e.xy2real(res.x), e.xy2real(res.y), frames[-1][3]))

r0 = math.hypot(e.xy2real(xi), e.xy2real(yi))
if mode == "rotate":
    t = math.radians(e.z2deg(zi))
    tx, ty = e.xy2real(xi) * math.cos(t) - e.xy2real(yi) * math.sin(t), e.xy2real(xi) * math.sin(t) + e.xy2real(yi) * math.cos(t)
else:
    tx, ty = r0, 0.0

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
                     "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED})
fig, (ax, ar) = plt.subplots(1, 2, figsize=(10.5, 5.0), facecolor=SURFACE, gridspec_kw={"width_ratios": [1.05, 1]})


def base(a):
    a.set_facecolor(SURFACE)
    for s in ("top", "right"):
        a.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        a.spines[s].set_color(AXIS)
    a.tick_params(length=0)


def draw(n):
    ax.clear()
    ar.clear()
    base(ax)
    base(ar)
    lim = 1.25 * max(r0, 0.3)
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.grid(color=GRID, linewidth=1)
    ax.set_axisbelow(True)
    c = plt.Circle((0, 0), r0, fill=False, color=AXIS, linewidth=1)
    ax.add_patch(c)
    ax.annotate("", xy=(e.xy2real(xi), e.xy2real(yi)), xytext=(0, 0),
                arrowprops=dict(arrowstyle="-|>", color=MUTED, linewidth=1.5))
    ax.annotate("", xy=(tx, ty), xytext=(0, 0),
                arrowprops=dict(arrowstyle="-|>", color=INK2, linewidth=1.2, linestyle=(0, (4, 3))))
    ax.annotate("target" if mode == "rotate" else "x axis", (tx, ty), textcoords="offset points",
                xytext=(0, -14 if mode == "vector" else 10), color=INK2, fontsize=9, ha="center", va="center")
    for k in range(1, n):
        ax.plot([0, frames[k][1]], [0, frames[k][2]], color=GRID, linewidth=1)
    title, x, y, _ = frames[n]
    ax.annotate("", xy=(x, y), xytext=(0, 0), arrowprops=dict(arrowstyle="-|>", color=BLUE, linewidth=2.5))
    ax.set_title("Rotation" if mode == "rotate" else "Vectoring", loc="left", fontsize=11, color=INK, pad=24)
    ax.text(0, 1.02, title, transform=ax.transAxes, fontsize=9.5, color=INK2, va="bottom", ha="left")

    # right: what is left, per iteration
    its = [k for k in range(len(frames)) if frames[k][0].startswith("iteration")]
    vals = [abs(frames[k][3]) for k in its]
    floor = (360.0 / 2 ** W) if mode == "rotate" else 2.0 ** -(W - 2)
    ar.set_yscale("log")
    ar.set_ylim(floor / 4, max(vals + [1.0]) * 2)
    ar.set_xlim(-0.5, len(its) - 0.5)
    ar.grid(axis="y", color=GRID, linewidth=1)
    ar.set_axisbelow(True)
    ar.axhline(floor, color=INK2, linewidth=1, linestyle=(0, (4, 3)))
    ar.text(len(its) - 0.6, floor * 1.25, "1 LSB", color=INK2, fontsize=9, ha="right", va="bottom")
    shown = [k for k in its if k <= n]
    xs = list(range(len(shown)))
    ys = [max(abs(frames[k][3]), floor / 3) for k in shown]
    ar.plot(xs, ys, color=BLUE, linewidth=2, marker="o", markersize=6, markeredgecolor=SURFACE, markeredgewidth=1.5)
    if shown:
        ar.plot([xs[-1]], [ys[-1]], marker="o", markersize=9, color=ORANGE, markeredgecolor=SURFACE, markeredgewidth=1.5)
    ar.set_xlabel("iteration")
    ar.set_title("Angle still to go (deg)" if mode == "rotate" else "y still left (vectoring drives it to 0)",
                 loc="left", fontsize=11, color=INK, pad=24)
    fig.tight_layout(w_pad=3)


def hold(title):                                      # how many animation frames each step stays
    return 3 if title == "input" else 2 if title.startswith("fold") else 6 if title.startswith("result") else 1


seq = [k for k in range(len(frames)) for _ in range(hold(frames[k][0]))]
anim = FuncAnimation(fig, draw, frames=seq, interval=600)
anim.save(out, writer=PillowWriter(fps=2), savefig_kwargs={"facecolor": SURFACE})
draw(len(frames) - 1)
png = os.path.splitext(out)[0] + ".png"
fig.savefig(png, dpi=150, facecolor=SURFACE)
print("wrote", out, "and", png)
