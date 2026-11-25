#!/usr/bin/env python3
"""python/foc_sim.py : the motor-control simulation of tb/tb_foc.sv in Python, with the bit-exact
model (python/cordic_model.py) in place of the RTL, so the demo runs without a simulator.

Same motor, same controller, same scenario and the same CSV columns as tb_foc.sv, with the math
in the same order, so the two logs can be compared line by line:

  python3 python/foc_sim.py [out.csv]                          default foc_python.csv
  python3 python/foc_sim.py out.csv --compare docs/foc_rtl.csv  and compare with the RTL's log

docs/foc_rtl.csv is the log of tb_foc.sv (RTL in the loop); this script reproduces it exactly.

Every 50 us step does three engine operations: Park (rotation by -theta), the voltage limit
(vectoring), and inverse Park with the clamped length (rotation by phi + theta).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cordic_model import Cordic   # noqa: E402

W, N = 16, 16
T_END = 0.14
PI = 3.14159265358979323846
SQRT3 = 1.7320508075688772
QXY = float(1 << (W - 2))
TURN = float(1 << W)
RPM = 60.0 / (2.0 * PI)

R_S, L_D, L_Q, PSI = 0.2, 0.4e-3, 0.4e-3, 0.01
J_M, B_M, POLES = 2.0e-5, 1.0e-5, 4.0
VDC = 24.0
V_MAX = VDC / SQRT3
I_MAX = 10.0
I_BASE, V_BASE = 10.0, 20.0
TS = 50.0e-6
SUB = 10
KT = 1.5 * POLES * PSI
KP_I, KI_I = L_D * 2.0 * PI * 1000.0, R_S * 2.0 * PI * 1000.0
KP_W = J_M * 2.0 * PI * 100.0 / KT
KI_W = KP_W * 2.0 * PI * 100.0 / 4.0
RAMP = 20000.0

ENGINE = Cordic(W, N)
HEADER = ("t_ms,w_ref_rpm,rpm_hw,rpm_float,iq_ref_a,id_hw_a,iq_hw_a,id_float_a,iq_float_a,ia_a,ib_a,ic_a,"
          "v_alpha_v,v_beta_v,v_mag_v,limited,theta_e_deg,load_nm,iq_meas_a,id_meas_a")


def deriv(s, va, vb, tl):
    idd, iqq, wm, thm = s
    te = POLES * thm
    we = POLES * wm
    c, sn = math.cos(te), math.sin(te)
    vd = va * c + vb * sn
    vq = -va * sn + vb * c
    return ((vd - R_S * idd + we * L_Q * iqq) / L_D,
            (vq - R_S * iqq - we * (L_D * idd + PSI)) / L_Q,
            (1.5 * POLES * (PSI * iqq + (L_D - L_Q) * idd * iqq) - B_M * wm - tl) / J_M,
            wm)


def axpy(s, d, h):
    return tuple(a + h * b for a, b in zip(s, d))


def rk4(s, va, vb, tl, h):
    k1 = deriv(s, va, vb, tl)
    k2 = deriv(axpy(s, k1, h / 2), va, vb, tl)
    k3 = deriv(axpy(s, k2, h / 2), va, vb, tl)
    k4 = deriv(axpy(s, k3, h), va, vb, tl)
    return tuple(s[j] + h / 6 * (k1[j] + 2 * k2[j] + 2 * k3[j] + k4[j]) for j in range(4))


def phase(s):
    idd, iqq, _, thm = s
    te = POLES * thm
    al = idd * math.cos(te) - iqq * math.sin(te)
    be = idd * math.sin(te) + iqq * math.cos(te)
    return al, -0.5 * al + 0.5 * SQRT3 * be


def clampr(v, lim):
    return lim if v > lim else (-lim if v < -lim else v)


def q(v):
    s = v * QXY
    c = int(s + (0.5 if s >= 0 else -0.5))
    return max(-(1 << (W - 1)), min((1 << (W - 1)) - 1, c))


def ang(rad):
    t = rad / (2.0 * PI)
    t = t - math.floor(t)
    c = int(t * TURN + 0.5) & ((1 << W) - 1)
    return c - (1 << W) if c >= (1 << (W - 1)) else c


def wrapc(c):
    c &= (1 << W) - 1
    return c - (1 << W) if c >= (1 << (W - 1)) else c


def simulate(path):
    rows = [HEADER]
    mh = mf = (0.0, 0.0, 0.0, 0.0)
    ii_d = ii_q = ii_w = 0.0
    f_ii_d = f_ii_q = f_ii_w = 0.0
    w_ramp = 0.0
    vmax_c = q(V_MAX / V_BASE)
    nstep = int(T_END / TS + 0.5)
    n_lim = n_ops = 0
    for k in range(nstep):
        t = k * TS
        w_cmd = 0.0 if t < 5.0e-3 else (3000.0 / RPM if t < 90.0e-3 else -1000.0 / RPM)
        iq_ff = J_M * clampr(w_cmd - w_ramp, RAMP * TS) / TS / KT
        w_ramp += clampr(w_cmd - w_ramp, RAMP * TS)
        w_ref = w_ramp
        tl = 0.25 if t >= 60.0e-3 else 0.0

        # hardware controller, the engine model in the loop
        ia, ib = phase(mh)
        ial, ibe = ia, (ia + 2.0 * ib) / SQRT3
        th = ang(POLES * mh[3])
        r = ENGINE.run(q(ial / I_BASE), q(ibe / I_BASE), wrapc(-th), 0, 0)          # Park
        idc, iqc = r.x, r.y
        idm, iqm = idc / QXY * I_BASE, iqc / QXY * I_BASE
        ew = w_ref - mh[2]
        iqr_u = KP_W * ew + ii_w + iq_ff
        iq_ref = clampr(iqr_u, I_MAX)
        if iq_ref == iqr_u or ew * iqr_u < 0:
            ii_w += KI_W * TS * ew
        we = POLES * mh[2]
        ed, eq = 0.0 - idm, iq_ref - iqm
        vd = KP_I * ed + ii_d - we * L_Q * iqm
        vq = KP_I * eq + ii_q + we * (L_D * idm + PSI)
        r = ENGINE.run(q(vd / V_BASE), q(vq / V_BASE), 0, 0, 1)                    # vectoring
        magc, phic = r.x, r.z
        lim = magc > vmax_c
        mc = vmax_c if lim else magc
        r = ENGINE.run(mc, 0, wrapc(phic + th), 0, 0)                               # inverse Park
        va, vb = r.x / QXY * V_BASE, r.y / QXY * V_BASE
        if not lim:
            ii_d += KI_I * TS * ed
            ii_q += KI_I * TS * eq
        n_lim += int(lim)
        n_ops += 3

        # the same controller in floating point
        fia, fib = phase(mf)
        fal, fbe = fia, (fia + 2.0 * fib) / SQRT3
        fth = POLES * mf[3]
        fid = fal * math.cos(fth) + fbe * math.sin(fth)
        fiq = -fal * math.sin(fth) + fbe * math.cos(fth)
        few = w_ref - mf[2]
        fiqr_u = KP_W * few + f_ii_w + iq_ff
        fiq_ref = clampr(fiqr_u, I_MAX)
        if fiq_ref == fiqr_u or few * fiqr_u < 0:
            f_ii_w += KI_W * TS * few
        fwe = POLES * mf[2]
        fed, feq = 0.0 - fid, fiq_ref - fiq
        fvd = KP_I * fed + f_ii_d - fwe * L_Q * fiq
        fvq = KP_I * feq + f_ii_q + fwe * (L_D * fid + PSI)
        fmag = math.sqrt(fvd * fvd + fvq * fvq)
        fphi = math.atan2(fvq, fvd)
        flim = fmag > V_MAX
        fm = V_MAX if flim else fmag
        fva, fvb = fm * math.cos(fphi + fth), fm * math.sin(fphi + fth)
        if not flim:
            f_ii_d += KI_I * TS * fed
            f_ii_q += KI_I * TS * feq

        the = POLES * mh[3]
        rows.append(f"{t * 1e3:.4f},{w_ref * RPM:.1f},{mh[2] * RPM:.3f},{mf[2] * RPM:.3f},{iq_ref:.4f},"
                    f"{mh[0]:.4f},{mh[1]:.4f},{mf[0]:.4f},{mf[1]:.4f},{ia:.4f},{ib:.4f},{-ia - ib:.4f},"
                    f"{va:.4f},{vb:.4f},{mc / QXY * V_BASE:.4f},{int(lim)},"
                    f"{(the - 2.0 * PI * math.floor(the / (2.0 * PI))) * 180.0 / PI:.3f},{tl:.3f},{iqm:.4f},{idm:.4f}")
        for _ in range(SUB):
            mh = rk4(mh, va, vb, tl, TS / SUB)
            mf = rk4(mf, fva, fvb, tl, TS / SUB)

    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")
    print(f"{nstep} control steps, {n_ops} engine operations, voltage limit active in {n_lim} steps; wrote {path}")
    return rows


def compare(a, b):
    la, lb = open(a).read().split("\n"), open(b).read().split("\n")
    diff = [i for i, (x, y) in enumerate(zip(la, lb)) if x != y]
    same = len(la) == len(lb) and not diff
    print(f"{'PASS' if same else 'FAIL'} {a} and {b}: {len(la) - 1} lines, "
          f"{len(diff) + abs(len(la) - len(lb))} different")
    for i in diff[:3]:
        print("  ", la[i], "\n  ", lb[i])
    return same


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--compare"]
    out = args[0] if args else "foc_python.csv"
    simulate(out)
    if "--compare" in sys.argv and len(args) > 1:
        sys.exit(0 if compare(out, args[1]) else 1)
