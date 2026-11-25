#!/usr/bin/env python3
"""python/plot_waves.py : timing diagrams from the waveform dump of tb/tb_waves.sv.

  python3 python/plot_waves.py <waves.vcd> [out folder] [slide]     default docs/

Writes wave_iterative.png (cordic_ss: one rotation, then a second back to back) and
wave_pipeline.png (cordic_pipe: results coming out through a 6-clock consumer stall).
Values are shown the way the testbench means them: x and y as reals (1.0 = 16384), angles in
degrees, the FSM state by name. With "slide" as the third argument it writes *_slide.png instead:
fewer rows, larger text and no title, for the presentation.
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker

SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, BLUE, ORANGE = "#e1e0d9", "#c3c2b7", "#2a78d6", "#eb6834"
PERIOD = 10000                                   # ps (10 ns clock in the testbench)
STYLE = {"fs": 1.0, "row": 0.62, "width": 15, "title": True}     # "slide" changes these


def read_vcd(path, scope="tb_waves"):
    """Changes of every variable directly in `scope`: name -> (width, [(time, int or None)])."""
    ids, sig, depth, in_scope, t = {}, {}, 0, False, 0
    with open(path) as f:
        lines = iter(f)
        for ln in lines:
            p = ln.split()
            if not p:
                continue
            if p[0] == "$scope":
                depth += 1
                if depth == 1 and p[2] == scope:
                    in_scope = True
            elif p[0] == "$upscope":
                depth -= 1
            elif p[0] == "$var" and in_scope and depth == 1 and p[1] != "real":
                ids.setdefault(p[3], []).append((p[4], int(p[2])))
                sig[p[4]] = (int(p[2]), [])
            elif p[0] == "$enddefinitions":
                break
        for ln in lines:
            ln = ln.strip()
            if not ln:
                continue
            c = ln[0]
            if c == "#":
                t = int(ln[1:])
                continue
            if c == "b":
                val, ident = ln[1:].split()
            elif c in "01xz":
                val, ident = c, ln[1:]
            else:
                continue
            for name, w in ids.get(ident, []):
                v = None if any(ch in "xz" for ch in val) else int(val, 2)   # unsigned; see signed()
                ch = sig[name][1]
                if not ch or ch[-1][1] != v:
                    ch.append((t, v))
    return sig


def signed(v, w):
    return v - (1 << w) if v >> (w - 1) & 1 else v


def value_at(changes, t):
    v = None
    for tt, vv in changes:
        if tt > t:
            break
        v = vv
    return v


def draw(sig, rows, t0, t1, title, path, notes=()):
    """rows: (signal, label, kind, fmt) with kind 'clk', 'bit' or 'bus'. t0, t1 in clocks."""
    n = len(rows)
    fs = STYLE["fs"]
    fig, ax = plt.subplots(figsize=(STYLE["width"], STYLE["row"] * n + 1.3), facecolor=SURFACE)
    ax.set_facecolor(SURFACE)
    a, b = t0 * PERIOD, t1 * PERIOD
    for tt, v in sig["clk"][1]:                        # a grid line at every rising edge
        if v == 1 and a <= tt <= b:
            ax.axvline(tt / PERIOD, color=GRID, linewidth=0.8, zorder=0)
    for r, (name, label, kind, fmt) in enumerate(rows):
        y = n - 1 - r
        ax.text(t0 - 0.3, y + 0.4, label, ha="right", va="center", fontsize=10 * fs, color=INK)
        ch = [(max(tt, a), v) for tt, v in sig[name][1] if tt < b]
        ch = [(a, value_at(sig[name][1], a))] + [c for c in ch if c[0] > a]
        segs = [(ch[k][0] / PERIOD, (ch[k + 1][0] if k + 1 < len(ch) else b) / PERIOD, ch[k][1]) for k in range(len(ch))]
        if kind in ("bit", "clk"):
            xs, ys = [], []
            for s, e, v in segs:
                yy = y + (0.7 if v else 0.1)
                xs += [s, e]
                ys += [yy, yy]
            ax.plot(xs, ys, color=INK2 if kind == "clk" else BLUE, linewidth=1.2 if kind == "clk" else 1.8)
            continue
        for s, e, v in segs:
            w = 0.12 if e - s > 0.3 else 0.0
            ax.fill([s, s + w, e - w, e, e - w, s + w], [y + 0.4, y + 0.7, y + 0.7, y + 0.4, y + 0.1, y + 0.1],
                    color="#e6eef9", edgecolor=BLUE, linewidth=1.0)
            txt = fmt(v) if v is not None else "x"
            if e - s >= 0.6 * max(1, len(txt) * 0.17 * fs):
                ax.text((s + e) / 2, y + 0.4, txt, ha="center", va="center", fontsize=8.5 * fs, color=INK)
    for k, note in enumerate(notes):                   # (x, text) or (x, text, "left" / "right")
        x, text = note[0], note[1]
        ha = note[2] if len(note) > 2 else ("right" if k == 0 else "left")
        ax.annotate(text, (x, n + 0.05), xytext=(-4 if ha == "right" else 4, 0), textcoords="offset points",
                    ha=ha, va="bottom", fontsize=9 * fs, color=ORANGE)
        ax.axvline(x, color=ORANGE, linewidth=1, linestyle=(0, (4, 3)), zorder=0)
    ax.set_xlim(t0 - 0.1, t1)
    ax.set_ylim(-0.3, n + 0.9)
    ax.set_yticks([])
    ax.set_xlabel("time (ns)", color=INK2, fontsize=10 * fs)
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v * PERIOD / 1000:.0f}"))
    ax.tick_params(colors=MUTED, length=0, labelsize=10 * fs)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    if STYLE["title"]:
        ax.set_title(title, loc="left", fontsize=12, color=INK, pad=22)
    fig.tight_layout()
    fig.subplots_adjust(left=0.13 if fs == 1.0 else 0.15)
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    print("wrote", path)


def first_change(sig, name, value, after=0):
    return next(t for t, v in sig[name][1] if v == value and t >= after)


def main():
    vcd = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs")
    sig = read_vcd(vcd)
    xy = lambda v: f"{signed(v, 16) / 16384:.4f}"
    xy3 = lambda v: f"{signed(v, 16) / 16384:.3f}"
    deg16 = lambda v: f"{signed(v, 16) * 360 / 65536:.1f}°"
    deg21 = lambda v: f"{signed(v, 23) * 360 / 2 ** 21:.1f}"
    lane = lambda v: f"{signed(v, 23) / 2 ** 19:.3f}"       # lane: 1.0 = 2^(14 + 5)
    state = lambda v: {0: "IDLE", 1: "EXE", 2: "DONE", 3: "HOLD"}.get(v, "?")

    slide = len(sys.argv) > 3 and sys.argv[3] == "slide"
    sfx = "_slide" if slide else ""
    if slide:
        STYLE.update(fs=1.7, row=0.85, width=16, title=False)

    s0 = first_change(sig, "start", 1) / PERIOD
    tv = first_change(sig, "out_valid", 1) / PERIOD
    rows = [("clk", "clk", "clk", None), ("start", "start", "bit", None), ("ready", "ready", "bit", None),
            ("z_in", "z_in (angle)", "bus", deg16), ("ss_state", "state", "bus", state),
            ("ss_i", "i", "bus", str), ("ss_z_lane", "z lane: angle left (°)", "bus", deg21),
            ("ss_x_lane", "x lane (before ×K)", "bus", lane), ("ss_y_lane", "y lane (before ×K)", "bus", lane),
            ("out_valid", "out_valid", "bit", None), ("x_corr", "x_corr", "bus", xy3), ("y_corr", "y_corr", "bus", xy3)]
    if slide:                                          # the rows that tell the story, larger
        keep = ("start", "ready", "ss_state", "ss_i", "ss_z_lane", "ss_x_lane", "out_valid", "x_corr")
        rows = [r for r in rows if r[0] in keep]
    draw(sig, rows, s0 - 1, s0 + (19 if slide else 21),
         "Iterative engine: rotate (0.5, 0) by 30° (result 0.433, 0.250), then start the next in the out_valid clock",
         os.path.join(out, f"wave_iterative{sfx}.png"),
         notes=[(s0 + 0.5, "start taken: lanes load" if slide else "start taken (ready = 1): lanes load, i = 0", "left"),
                (tv, "out_valid: (0.433, 0.250)" if slide else
                 "out_valid: x_corr, y_corr = 0.433, 0.250; next start taken", "right")])

    st = first_change(sig, "p_out_ready", 0) / PERIOD
    ti = first_change(sig, "p_in_ready", 0, after=st * PERIOD) / PERIOD
    tr = first_change(sig, "p_out_ready", 1, after=st * PERIOD) / PERIOD
    rows = [("clk", "clk", "clk", None), ("p_in_valid", "in_valid", "bit", None),
            ("p_in_ready", "in_ready", "bit", None), ("p_in_tag", "in_tag", "bus", str),
            ("p_out_valid", "out_valid", "bit", None), ("p_out_ready", "out_ready", "bit", None),
            ("p_skid_full", "skid entry full", "bit", None), ("p_out_tag", "out_tag", "bus", str),
            ("p_x", "x_corr", "bus", xy)]
    if slide:                                          # no clock row, 2 decimals so the values fit
        xy2 = lambda v: f"{signed(v, 16) / 16384:.2f}"
        rows = [r if r[0] != "p_x" else ("p_x", "x_corr", "bus", xy2) for r in rows if r[0] != "clk"]
    draw(sig, rows, st - 5, st + 13, "Pipelined engine (18 ranks): the consumer stalls for 6 clocks while results come out",
         os.path.join(out, f"wave_pipeline{sfx}.png"),
         notes=[(st, "consumer stops"), (ti, "skid fills, in_ready drops"), (tr, "consumer resumes")] if slide else
               [(st, "consumer stops (out_ready = 0)"), (ti, "skid entry fills, in_ready drops"),
                (tr, "consumer resumes")])

if __name__ == "__main__":
    main()
