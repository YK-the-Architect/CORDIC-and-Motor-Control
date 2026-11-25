#!/usr/bin/env python3
"""python/calculator.py : a calculator that answers with the CORDIC engine's exact bits.

It runs python/cordic_model.py, which gives the same results as the RTL bit for bit (checked by
python/check_model.py), and prints the answer next to real math, the error in LSBs, the codes the
hardware sees, and how many clocks each engine takes.

  python3 python/calculator.py                    interactive
  python3 python/calculator.py rotate 0.5 0 30    one command

Commands (x, y in [-2, 2); angles in degrees):
  rotate x y deg     (x, y) rotated by deg                      circular rotation
  sincos deg         sin and cos of deg, from rotating (1, 0)   circular rotation
  vector x y         |(x, y)| and its angle atan2(y, x)         circular vectoring
  mul x z            x * z, |z| < 1                             linear rotation
  div y x            y / x, |y| < |x|                           linear vectoring
  width W [N]        change the word width and iterations (default 16 16)
  help, quit
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cordic_model import Cordic   # noqa: E402

engine = Cordic(16, 16)
PIPE_RANKS = 18                    # the pipeline that meets 800 MHz (docs/pipeline_ppa.md)


def hexw(v):
    w = engine.W
    return f"0x{v & ((1 << w) - 1):0{(w + 3) // 4}X}"


def show(mode, ins, outs, lines):
    """Print the codes, the answers and the clocks."""
    cl, rv = mode
    w, n = engine.W, engine.N
    print(f"  in   x {hexw(ins[0])}  y {hexw(ins[1])}  z {hexw(ins[2])}   mode_cl {cl} mode_rv {rv}")
    print(f"  out  x {hexw(outs.x)}  y {hexw(outs.y)}  z {hexw(outs.z)}   ovf {int(outs.ovf)}")
    for text in lines:
        print("  " + text)
    lat_ss = n + (0 if cl else 1)
    print(f"  clocks: iterative engine {lat_ss} (one result at a time), pipeline "
          f"{PIPE_RANKS + 1} (a new operation every clock)" if (w, n) == (16, 16) else
          f"  clocks: iterative engine {lat_ss}")
    if outs.ovf:
        print("  ovf = 1: a result was saturated, or the inputs are out of range for this operation")


def err(got, real, scale):
    return f"error {abs(got - real) * scale:.2f} LSB"


def do(cmd, args):
    e = engine
    f = [float(a) for a in args]
    sxy, slin, sz = 1 << (e.W - 2), 1 << (e.W - 1), (1 << e.W) / 360.0
    if cmd == "rotate" and len(f) == 3:
        ins = (e.q_xy(f[0]), e.q_xy(f[1]), e.deg2z(f[2]))
        r = e.run(*ins, 0, 0)
        x0, y0, th = e.xy2real(ins[0]), e.xy2real(ins[1]), math.radians(e.z2deg(ins[2]))
        ex, ey = x0 * math.cos(th) - y0 * math.sin(th), x0 * math.sin(th) + y0 * math.cos(th)
        show((0, 0), ins, r, [f"x' = {e.xy2real(r.x):+.6f}   real {ex:+.6f}   {err(e.xy2real(r.x), ex, sxy)}",
                              f"y' = {e.xy2real(r.y):+.6f}   real {ey:+.6f}   {err(e.xy2real(r.y), ey, sxy)}"])
    elif cmd == "sincos" and len(f) == 1:
        ins = (e.q_xy(1.0), 0, e.deg2z(f[0]))
        r = e.run(*ins, 0, 0)
        th = math.radians(e.z2deg(ins[2]))
        show((0, 0), ins, r, [f"cos = {e.xy2real(r.x):+.6f}   real {math.cos(th):+.6f}   {err(e.xy2real(r.x), math.cos(th), sxy)}",
                              f"sin = {e.xy2real(r.y):+.6f}   real {math.sin(th):+.6f}   {err(e.xy2real(r.y), math.sin(th), sxy)}"])
    elif cmd == "vector" and len(f) == 2:
        ins = (e.q_xy(f[0]), e.q_xy(f[1]), 0)
        r = e.run(*ins, 0, 1)
        x0, y0 = e.xy2real(ins[0]), e.xy2real(ins[1])
        m, a = math.hypot(x0, y0), math.degrees(math.atan2(y0, x0))
        da = (e.z2deg(r.z) - a + 180.0) % 360.0 - 180.0
        show((0, 1), ins, r, [f"|v|   = {e.xy2real(r.x):.6f}   real {m:.6f}   {err(e.xy2real(r.x), m, sxy)}",
                              f"angle = {e.z2deg(r.z):+.4f} deg   real {a:+.4f}   error {abs(da) * sz:.2f} LSB"])
    elif cmd == "mul" and len(f) == 2:
        ins = (e.q_xy(f[0]), 0, e.q_lin(f[1]))
        r = e.run(*ins, 1, 0)
        p = e.xy2real(ins[0]) * e.lin2real(ins[2])
        show((1, 0), ins, r, [f"x * z = {e.xy2real(r.y):+.6f}   real {p:+.6f}   {err(e.xy2real(r.y), p, sxy)}"])
    elif cmd == "div" and len(f) == 2:
        ins = (e.q_xy(f[1]), e.q_xy(f[0]), 0)
        r = e.run(*ins, 1, 1)
        x0, y0 = e.xy2real(ins[0]), e.xy2real(ins[1])
        if abs(y0) >= abs(x0):
            lines = [f"y / x = {e.lin2real(r.z):+.6f}   out of range: needs |y| < |x| (the result saturates)"]
        else:
            lines = [f"y / x = {e.lin2real(r.z):+.6f}   real {y0 / x0:+.6f}   {err(e.lin2real(r.z), y0 / x0, slin)}"]
        show((1, 1), ins, r, lines)
    elif cmd == "width" and len(f) in (1, 2):
        globals()["engine"] = Cordic(int(f[0]), int(f[1]) if len(f) > 1 else int(f[0]))
        print(f"  W = {engine.W}, N = {engine.N}, G = {engine.G} guard bits")
    else:
        print("  ?  try: rotate 0.5 0 30 | sincos 30 | vector 0.3 0.4 | mul 0.75 -0.5 | div 0.3 0.8 | width 12")


def main():
    if len(sys.argv) > 1:
        do(sys.argv[1], sys.argv[2:])
        return
    print(f"CORDIC calculator: W = {engine.W}, N = {engine.N}. Same bits as the RTL. 'help' lists the commands.")
    while True:
        try:
            line = input("cordic> ").split()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        if line[0] in ("quit", "exit", "q"):
            break
        if line[0] == "help":
            print(__doc__.split("Commands")[1])
            continue
        try:
            do(line[0], line[1:])
        except ValueError:
            print("  numbers please, e.g. rotate 0.5 0 30")


if __name__ == "__main__":
    main()
