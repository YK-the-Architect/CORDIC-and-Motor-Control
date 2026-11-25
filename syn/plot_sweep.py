#!/usr/bin/env python3
"""syn/plot_sweep.py : the pipeline-depth sweep as two charts (clock, area) for the report.

  python3 syn/plot_sweep.py <results.json from run_ppa.py> <out.png> [font size, default 10]
"""
import json, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, BLUE = "#e1e0d9", "#c3c2b7", "#2a78d6"

rows = {r["name"]: r for r in json.load(open(sys.argv[1]))}
pipe = sorted((int(n[6:]), r) for n, r in rows.items() if re.fullmatch(r"pipe_r\d+", n))
R = [k for k, _ in pipe]
fmax = [r["fmax_mhz"] for _, r in pipe]
area = [r["area_um2"] / 1000 for _, r in pipe]

FONT = float(sys.argv[3]) if len(sys.argv) > 3 else 10
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": FONT, "text.color": INK,
                     "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED})
fig, axs = plt.subplots(1, 2, figsize=(11 * FONT / 10, 4.2 * FONT / 10), facecolor=SURFACE)


def style(ax, title, ylabel):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, loc="left", fontsize="large", color=INK, pad=10)
    ax.set_xlabel("register ranks (latency = ranks + 1 clocks)")
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color=GRID, linewidth=1)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(AXIS)
    ax.tick_params(length=0)
    ax.set_xticks(R)


def ref(ax, y, text, right=False):
    ax.axhline(y, color=INK2, linewidth=1, linestyle=(0, (4, 3)), zorder=1)
    if right:
        ax.text(R[-1] + 0.3, y, text, color=INK2, fontsize="small", va="top", ha="right")
    else:
        ax.text(R[0] - 0.3, y, text, color=INK2, fontsize="small", va="bottom", ha="left")


ax = axs[0]
style(ax, "Fastest clock that meets setup (MHz)", "MHz")
ax.plot(R, fmax, color=BLUE, linewidth=2, marker="o", markersize=6, zorder=3,
        markeredgecolor=SURFACE, markeredgewidth=1.5)
ref(ax, rows["iter"]["fmax_mhz"], f"iterative engine, {rows['iter']['fmax_mhz']:.0f}", right=True)
ref(ax, rows["iter_mcp"]["fmax_mhz"], f"iterative + multicycle path, {rows['iter_mcp']['fmax_mhz']:.0f}")
ref(ax, 800, "800 MHz target")
for k, f in zip(R, fmax):
    if k in (0, 8, 16, 18, 20):
        ax.annotate(f"{f:.0f}", (k, f), textcoords="offset points", xytext=(0, 8), ha="center",
                    fontsize="small", color=INK)
ax.set_ylim(0, 1050)

ax = axs[1]
style(ax, "Area (thousand um², NanGate 45 nm)", "thousand um²")
ax.plot(R, area, color=BLUE, linewidth=2, marker="o", markersize=6, zorder=3,
        markeredgecolor=SURFACE, markeredgewidth=1.5)
ref(ax, rows["iter"]["area_um2"] / 1000, f"iterative engine, {rows['iter']['area_um2'] / 1000:.1f}")
for k, a in zip(R, area):
    if k in (0, 18, 20):
        ax.annotate(f"{a:.1f}", (k, a), textcoords="offset points", xytext=(0, 8), ha="center",
                    fontsize="small", color=INK)
ax.set_ylim(0, 30)

fig.tight_layout(w_pad=3)
fig.savefig(sys.argv[2], dpi=160, facecolor=SURFACE)
print("wrote", sys.argv[2])
