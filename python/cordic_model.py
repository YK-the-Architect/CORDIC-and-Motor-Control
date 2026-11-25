#!/usr/bin/env python3
"""python/cordic_model.py : bit-exact model of the CORDIC engine.

Gives the same x, y, z and ovf as rtl/cordic_ss.sv (and rtl/cordic_pipe.sv, which matches it bit
for bit) for any WIDTH, ITER and G, by doing the same integer steps: the 180 deg input fold, lanes
of W + 2 + G bits that wrap like the add/sub, arithmetic shifts, the atan table read from
rtl/atan_rom.sv, x K, banker's rounding, saturation and the sticky ovf flag. python/check_model.py
checks it against the RTL.

Formats (same as the RTL):
  x, y   Q2.(W-2): 1.0 = 2^(W-2), range [-2, 2)
  z      circular: binary angle, 2^W = 360 deg; linear: Q1.(W-1), range [-1, 1)
Modes:   cl = 0 circular, 1 linear;  rv = 0 rotation, 1 vectoring
  rotation   (cl 0, rv 0): (x, y) rotated by z                     z -> about 0
  vectoring  (cl 0, rv 1): x = |(x, y)|, z = z_in + atan2(y, x)   y -> about 0
  multiply   (cl 1, rv 0): y = y_in + x * z
  divide     (cl 1, rv 1): z = z_in + y / x (|y| < |x|)

  from cordic_model import Cordic
  e = Cordic(W=16, N=16)
  r = e.run(x, y, z, cl=0, rv=0)      # ints in, Result(x, y, z, ovf) out
  e.rotate(0.5, 0.0, 30.0)            # real in, real out (degrees for angles)

Run it to print a few results next to real math:  python3 python/cordic_model.py
"""
import math
import os
import re
from collections import namedtuple

Result = namedtuple("Result", "x y z ovf")

K_INV = 0.6072529                       # the constant rtl/error_correction.sv rounds to F bits
MASTER = 48                             # rtl/atan_rom.sv: 2^48 = 360 deg in the stored constants
HERE = os.path.dirname(os.path.abspath(__file__))
ATAN_ROM = os.path.join(HERE, "..", "rtl", "atan_rom.sv")


def clog2(n):
    return (n - 1).bit_length()


def sx(v, n):
    """v as an n-bit two's complement number (wraps, like taking the low n bits in SV)."""
    v &= (1 << n) - 1
    return v - (1 << n) if v >> (n - 1) else v


def atan_turns():
    """The 48-bit constants of rtl/atan_rom.sv (computed the same way if the file is missing)."""
    try:
        text = open(ATAN_ROM).read()
        vals = {int(i): int(v) for i, v in re.findall(r"(\d+):\s*atan_turns\s*=\s*48'd(\d+)", text)}
        return [vals[i] for i in range(len(vals))]
    except OSError:
        return [round(math.atan(2.0 ** -i) / (2 * math.pi) * 2 ** MASTER) for i in range(32)]


def round_even(v, s):
    """rtl/error_correction.sv round_even: drop s fraction bits, ties to even."""
    if s == 0:
        return v
    q = v >> s
    g = (v >> (s - 1)) & 1
    below = v & ((1 << (s - 1)) - 1)
    return q + (g & (int(below != 0) | (q & 1)))


def add_sub(a, b, sub, n):
    """rtl/add_sub.sv: n-bit result (wraps) and the overflow flag."""
    r = a - b if sub else a + b
    return sx(r, n), not (-(1 << (n - 1)) <= r < (1 << (n - 1)))


class Cordic:
    def __init__(self, W=16, N=16, G=None, F=None):
        self.W, self.N = W, N
        self.G = clog2(N) + 1 if G is None else G       # cordic_ss default
        self.F = W + 2 if F is None else F              # error_correction: fraction bits of K
        self.IW = W + 2 + self.G                        # lane width
        self.C = int(math.floor(K_INV * 2.0 ** self.F + 0.5))   # SV int'() rounds to nearest
        ab = W + self.G                                 # atan_rom ANGLE_BITS
        t = atan_turns()
        self.atan = [((t[i] + (1 << (MASTER - ab - 1))) >> (MASTER - ab)) & ((1 << self.IW) - 1)
                     for i in range(N)]
        self.one = 1 << (W - 1 + self.G)                # 1.0 in the z lane, linear mode
        self.maxv, self.minv = (1 << (W - 1)) - 1, -(1 << (W - 1))

    # ---------------- integer model, one operation ----------------
    def run(self, x_in, y_in, z_in, cl=0, rv=0, trace=None):
        """One operation, ints in (any int, the low W bits are used), Result out.
        trace: a list to append (i, x, y, z) lane values after each iteration (for animations)."""
        W, G, IW, N = self.W, self.G, self.IW, self.N
        x_in, y_in, z_in = sx(x_in, W), sx(y_in, W), sx(z_in, W)
        cl, rv = int(bool(cl)), int(bool(rv))

        # input stage (datapath.sv): fold by 180 deg in circular mode, negate for divide by x < 0
        if cl:
            fold = False
        elif rv:
            fold = x_in < 0
        else:
            fold = bool(((z_in >> (W - 1)) ^ (z_in >> (W - 2))) & 1)    # quadrant II or III
        neg = fold or (cl and rv and x_in < 0)
        x, y = x_in << G, y_in << G
        if neg:
            x, y = -x, -y
        zf = sx(z_in ^ (1 << (W - 1)), W) if fold else z_in
        z = zf << G
        zhold = (not cl) and rv and x_in == 0 and y_in == 0
        ovf = bool(cl and rv and abs(y_in) >= abs(x_in))               # div_bad
        if trace is not None:
            trace.append((-1, x, y, z))

        # iterations (control.sv EXE): i = 0 (circular) or 1 (linear) to N - 1
        for i in range(1 if cl else 0, N):
            sigma = (y < 0) if rv else (z >= 0)
            ys = 0 if cl else (y >> i)
            ang = (self.one >> i) if cl else self.atan[i]
            xn, ox = add_sub(x, ys, sigma, IW)
            yn, oy = add_sub(y, x >> i, not sigma, IW)
            zn, oz = add_sub(z, ang, sigma, IW)
            ovf |= ox | oy | oz
            x, y = xn, yn
            if not zhold:
                z = zn
            if trace is not None:
                trace.append((i, x, y, z))

        # output stage (error_correction.sv)
        if cl:
            xr, yr = round_even(x, G), round_even(y, G)
        else:
            xr, yr = round_even(x * self.C, self.F + G), round_even(y * self.C, self.F + G)
        zr = round_even(z, G)
        xo, yo = self._clamp(xr), self._clamp(yr)
        ovf |= xo != xr or yo != yr
        if cl:
            zo = self._clamp(zr)
            ovf |= zo != zr
        else:
            zo = sx(zr, W)                       # an angle wraps
        return Result(xo, yo, zo, bool(ovf))

    def _clamp(self, v):
        return self.maxv if v > self.maxv else self.minv if v < self.minv else v

    # ---------------- the same, on numpy arrays (one mode per call) ----------------
    def run_np(self, x_in, y_in, z_in, cl=0, rv=0):
        """Vectorized run(): x_in, y_in, z_in int arrays (or scalars), cl and rv scalars.
        Returns (x, y, z, ovf) arrays. Bit-exact with run()."""
        import numpy as np
        W, G, IW, N = self.W, self.G, self.IW, self.N

        def wrap(v, n):
            return ((v + (1 << (n - 1))) & ((1 << n) - 1)) - (1 << (n - 1))

        def rnd(v, s):
            if s == 0:
                return v
            q = v >> s
            g = (v >> (s - 1)) & 1
            below = v & ((1 << (s - 1)) - 1)
            return q + (g & ((below != 0).astype(np.int64) | (q & 1)))

        def addsub(a, b, sub, n):
            r = np.where(sub, a - b, a + b)
            return wrap(r, n), (r < -(1 << (n - 1))) | (r >= (1 << (n - 1)))

        x_in = wrap(np.asarray(x_in, dtype=np.int64), W)
        y_in = wrap(np.asarray(y_in, dtype=np.int64), W)
        z_in = wrap(np.asarray(z_in, dtype=np.int64), W)
        x_in, y_in, z_in = np.broadcast_arrays(x_in, y_in, z_in)
        cl, rv = int(bool(cl)), int(bool(rv))
        if cl:
            fold = np.zeros(x_in.shape, bool)
        elif rv:
            fold = x_in < 0
        else:
            fold = (((z_in >> (W - 1)) ^ (z_in >> (W - 2))) & 1).astype(bool)
        neg = fold | ((x_in < 0) if (cl and rv) else False)
        x = np.where(neg, -(x_in << G), x_in << G)
        y = np.where(neg, -(y_in << G), y_in << G)
        z = np.where(fold, wrap(z_in ^ (1 << (W - 1)), W), z_in) << G
        zhold = ((x_in == 0) & (y_in == 0)) if (not cl and rv) else np.zeros(x_in.shape, bool)
        ovf = (np.abs(y_in) >= np.abs(x_in)) if (cl and rv) else np.zeros(x_in.shape, bool)

        for i in range(1 if cl else 0, N):
            sigma = (y < 0) if rv else (z >= 0)
            ys = 0 if cl else (y >> i)
            ang = (self.one >> i) if cl else self.atan[i]
            xn, ox = addsub(x, ys, sigma, IW)
            yn, oy = addsub(y, x >> i, ~sigma, IW)
            zn, oz = addsub(z, ang, sigma, IW)
            ovf = ovf | ox | oy | oz
            x, y = xn, yn
            z = np.where(zhold, z, zn)

        if cl:
            xr, yr = rnd(x, G), rnd(y, G)
        else:
            xr, yr = rnd(x * self.C, self.F + G), rnd(y * self.C, self.F + G)
        zr = rnd(z, G)
        xo, yo = np.clip(xr, self.minv, self.maxv), np.clip(yr, self.minv, self.maxv)
        ovf = ovf | (xo != xr) | (yo != yr)
        if cl:
            zo = np.clip(zr, self.minv, self.maxv)
            ovf = ovf | (zo != zr)
        else:
            zo = wrap(zr, W)
        return xo, yo, zo, ovf

    # ---------------- real-valued helpers ----------------
    def q_xy(self, v):
        """real -> Q2.(W-2) code, rounded, clamped."""
        return self._clamp(int(math.floor(v * (1 << (self.W - 2)) + 0.5)))

    def q_lin(self, v):
        """real -> Q1.(W-1) code (linear-mode z), rounded, clamped."""
        return self._clamp(int(math.floor(v * (1 << (self.W - 1)) + 0.5)))

    def deg2z(self, deg):
        """degrees -> binary angle code (wraps)."""
        return sx(int(math.floor(deg / 360.0 * (1 << self.W) + 0.5)), self.W)

    def xy2real(self, c):
        return c / (1 << (self.W - 2))

    def lin2real(self, c):
        return c / (1 << (self.W - 1))

    def z2deg(self, c):
        return c * 360.0 / (1 << self.W)

    def rotate(self, x, y, deg):
        """(x, y) rotated by deg degrees: returns (x', y', ovf) as reals."""
        r = self.run(self.q_xy(x), self.q_xy(y), self.deg2z(deg), 0, 0)
        return self.xy2real(r.x), self.xy2real(r.y), r.ovf

    def vector(self, x, y):
        """magnitude and angle (degrees) of (x, y): returns (|v|, deg, ovf)."""
        r = self.run(self.q_xy(x), self.q_xy(y), 0, 0, 1)
        return self.xy2real(r.x), self.z2deg(r.z), r.ovf

    def multiply(self, x, z):
        """x * z, |z| < 1: returns (product, ovf)."""
        r = self.run(self.q_xy(x), 0, self.q_lin(z), 1, 0)
        return self.xy2real(r.y), r.ovf

    def divide(self, y, x):
        """y / x, |y| < |x|: returns (quotient, ovf)."""
        r = self.run(self.q_xy(x), self.q_xy(y), 0, 1, 1)
        return self.lin2real(r.z), r.ovf


if __name__ == "__main__":
    e = Cordic(16, 16)
    print(f"W = {e.W}, N = {e.N}, G = {e.G}, lanes {e.IW} bits, K = {e.C} / 2^{e.F}")
    lsb = 2.0 ** -(e.W - 2)
    for x, y, d in [(0.5, 0.0, 30.0), (0.6, -0.3, 135.0), (1.0, 0.0, -90.0)]:
        xr, yr, ov = e.rotate(x, y, d)
        t = math.radians(d)
        ex, ey = x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t)
        print(f"rotate ({x}, {y}) by {d} deg: ({xr:.5f}, {yr:.5f})  real ({ex:.5f}, {ey:.5f})  "
              f"error {abs(xr - ex) / lsb:.2f}, {abs(yr - ey) / lsb:.2f} LSB  ovf {int(ov)}")
    m, a, ov = e.vector(-0.3, 0.4)
    print(f"vector (-0.3, 0.4): |v| = {m:.5f} (0.5), angle {a:.4f} deg ({math.degrees(math.atan2(0.4, -0.3)):.4f})")
    p, ov = e.multiply(0.75, -0.5)
    print(f"multiply 0.75 * -0.5 = {p:.5f}")
    qd, ov = e.divide(0.3, 0.8)
    print(f"divide 0.3 / 0.8 = {qd:.5f} (0.375)")
