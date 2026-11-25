#!/usr/bin/env python3
"""python/plot_foc.py : charts of the motor-control simulation (tb/tb_foc.sv or python/foc_sim.py).

  python3 python/plot_foc.py [log.csv] [out.png] [slide]   defaults docs/foc_rtl.csv, docs/foc.png

Four panels: speed (command and the loop with the CORDIC engine), the d and q currents, the three
phase currents around the load step, and the voltage the controller asks for against the limit.
With "slide": only the first two, side by side, for a slide.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "docs", "foc_rtl.csv")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "docs", "foc.png")

SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, AXIS = "#e1e0d9", "#c3c2b7"
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"     # categorical slots 1 to 3

rows = list(csv.DictReader(open(SRC)))
col = {k: [float(r[k]) for r in rows] for k in rows[0]}
t = col["t_ms"]
EVENTS = [(5.0, "speed command"), (60.0, "load 0.25 N m"), (90.0, "reversal")]

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
                     "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED})
SLIDE = len(sys.argv) > 3 and sys.argv[3] == "slide"
if SLIDE:
    plt.rcParams.update({"font.size": 14})
    fig, row = plt.subplots(1, 2, figsize=(14, 5.0), facecolor=SURFACE)
    axs = [[row[0], row[1]], [None, None]]
else:
    fig, axs = plt.subplots(2, 2, figsize=(12, 7.2), facecolor=SURFACE)


def style(ax, title, ylabel, xlabel="time (ms)"):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, loc="left", fontsize="large", color=INK, pad=10)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color=GRID, linewidth=1)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(AXIS)
    ax.tick_params(length=0)


def events(ax, label=True):
    for x, text in EVENTS:
        ax.axvline(x, color=AXIS, linewidth=1, zorder=1)
        if label:
            ax.text(x + 1.0, 1.0, text, transform=ax.get_xaxis_transform(), color=INK2, fontsize="small",
                    va="top", ha="left")


def label_end(ax, x, y, text, color, dy=0):
    ax.annotate(text, (x, y), textcoords="offset points", xytext=(6, dy), color=INK2, fontsize="small",
                va="center", ha="left")
    ax.plot([x], [y], marker="o", markersize=5, color=color, markeredgecolor=SURFACE, markeredgewidth=1.5)


# speed
ax = axs[0][0]
style(ax, "Speed (rpm)", "rpm")
events(ax)
ax.plot(t, col["w_ref_rpm"], color=INK2, linewidth=1.2, linestyle=(0, (4, 3)), label="command")
ax.plot(t, col["rpm_hw"], color=BLUE, linewidth=2, label="motor, CORDIC engine in the loop")
ax.set_ylim(-1900, 3800)
ax.set_xlim(0, t[-1] + 12)
diff = max(abs(a - b) for a, b in zip(col["rpm_hw"], col["rpm_float"]))
ax.text(0.99, 0.03, f"same controller in floating point: within {diff:.2f} rpm", transform=ax.transAxes,
        ha="right", va="bottom", fontsize="small", color=INK2)
ax.legend(loc="lower left", frameon=False, fontsize="small", bbox_to_anchor=(0.0, 0.16))

# d and q currents
ax = axs[0][1]
style(ax, "Rotor-frame currents (A)", "A")
events(ax, label=False)
ax.plot(t, col["iq_ref_a"], color=INK2, linewidth=1.2, linestyle=(0, (4, 3)), label="i_q command")
ax.plot(t, col["iq_hw_a"], color=BLUE, linewidth=2, label="i_q (torque)")
ax.plot(t, col["id_hw_a"], color=ORANGE, linewidth=2, label="i_d (held at 0)")
ax.set_xlim(0, t[-1] + 12)
ax.set_ylim(-11, 11)
label_end(ax, t[-1], col["iq_hw_a"][-1], "i_q", BLUE)
label_end(ax, t[-1], col["id_hw_a"][-1], "i_d", ORANGE)
ax.legend(loc="lower left", frameon=False, fontsize="small", ncol=3)

if SLIDE:
    fig.tight_layout(w_pad=3)
    fig.savefig(OUT, dpi=160, facecolor=SURFACE)
    print("wrote", OUT)
    sys.exit(0)

# phase currents around the load step
ax = axs[1][0]
lo, hi = 58.0, 66.0
idx = [k for k, v in enumerate(t) if lo <= v <= hi]
style(ax, "Phase currents around the load step (A)", "A")
ax.axvline(60.0, color=AXIS, linewidth=1, zorder=1)
ax.text(60.15, 1.0, "load 0.25 N m", transform=ax.get_xaxis_transform(), color=INK2, fontsize="small", va="top")
for name, c in (("ia_a", BLUE), ("ib_a", ORANGE), ("ic_a", AQUA)):
    ax.plot([t[k] for k in idx], [col[name][k] for k in idx], color=c, linewidth=1.8, label=name[:2].replace("i", "i_"))
ax.set_xlim(lo, hi)
ax.set_ylim(-7.5, 7.5)
ax.legend(loc="lower right", frameon=False, fontsize="small", ncol=3)

# voltage
ax = axs[1][1]
style(ax, "Voltage the controller applies (V)", "V")
events(ax, label=False)
vmax = 24.0 / 3 ** 0.5
ax.axhline(vmax, color=INK2, linewidth=1, linestyle=(0, (4, 3)))
ax.text(1.0, vmax + 0.25, f"limit {vmax:.1f} V (24 V bus)", color=INK2, fontsize="small", va="bottom")
ax.plot(t, col["v_mag_v"], color=BLUE, linewidth=2, label="|v| after the limit")
lim_t = [t[k] for k, r in enumerate(rows) if r["limited"] == "1"]
ax.plot(lim_t, [vmax] * len(lim_t), linestyle="none", marker="o", markersize=5, color=ORANGE,
        markeredgecolor=SURFACE, markeredgewidth=1.0, label="steps where the limit acted")
ax.set_xlim(0, t[-1] + 12)
ax.set_ylim(0, 18)
ax.legend(loc="upper right", frameon=False, fontsize="small")

fig.tight_layout(h_pad=2.5, w_pad=3)
fig.savefig(OUT, dpi=160, facecolor=SURFACE)
print("wrote", OUT)
