#!/usr/bin/env python3
"""syn/run_ppa.py : synthesis, static timing and power for the CORDIC engines.

Yosys maps the RTL to a standard cell library; OpenSTA times the netlist with the SDC files in
syn/ and reports power. For each configuration it records area, cells and flops, the fastest
clock that meets setup (found by bisection), the critical path, slack at a target clock, hold
slack, design-rule violations and power.

  python3 syn/run_ppa.py --lib NangateOpenCellLibrary_typical.lib --sta /path/to/sta \\
      --out /tmp/ppa --points points.json [--target 1.25] [--only iter,pipe_r19] [--power] [--reuse]

--points comes from syn/balance.py. --power also runs every netlist in a gate-level simulation
next to its RTL (syn/tb_power.sv, Verilator), checks they match, and reports power from that
switching activity. --reuse keeps netlists that are already there.

Needs yowasp-yosys (pip install yowasp-yosys), verilator and an OpenSTA binary. Results go to
<out>/results.csv, <out>/results.json and <out>/power.json; every run keeps its scripts, logs
and reports in <out>/<name>/.
"""
import argparse, csv, glob, json, os, re, shutil, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = sorted(glob.glob(os.path.join(REPO, "rtl", "*.sv")))
MULT = [os.path.join(REPO, "compare", f) for f in ("sin_table.sv", "mult_rot.sv")] + [os.path.join(REPO, "rtl", "csa_tree.sv")]
W, N = 16, 16
NC = N + 4                                  # cut points in cordic_pipe

# ABC: delay-oriented mapping that keeps the adder structure Yosys builds (Brent-Kung), then
# buffering and gate sizing toward the delay target. The default ABC scripts restructure for
# area first and turn the fast adders back into ripple-carry chains (2.1x slower on a 42-bit add).
ABC_SCRIPT = "+strash;&get,-n;&nf,-D,{D};&put;buffer;upsize,-D,{D};dnsize,-D,{D};stime,-p"


def cuts_value(positions):
    """CUTS parameter for cordic_pipe: a register after each listed cut point."""
    v = 0
    for p in positions:
        v |= 1 << p
    return f"{NC}'b{v:0{NC}b}"


def configs():
    """Every design point. The pipeline points add register ranks at the cut points that keep the
    stages balanced (see docs/pipeline_ppa.md)."""
    c = []
    # power workloads: (label, tb_power define, tb_power parameters); GAP = clocks per operation
    ss0 = [("full", "SS", dict(OUT_WAIT=0))]
    ss1 = [("full", "SS", dict(OUT_WAIT=1))]
    c.append(dict(name="iter", top="cordic_ss", params=dict(WIDTH=W, ITER=N), sdc="syn/cordic_ss.sdc",
                  keep="error_correction", note="iterative engine as on main", power=ss0))
    c.append(dict(name="iter_wait_nomcp", top="cordic_ss", params=dict(WIDTH=W, ITER=N, OUT_WAIT=1),
                  sdc="syn/cordic_ss.sdc", keep="error_correction", note="OUT_WAIT = 1, timed without the exception"))
    c.append(dict(name="iter_mcp", top="cordic_ss", params=dict(WIDTH=W, ITER=N, OUT_WAIT=1),
                  sdc="syn/cordic_ss_mcp.sdc", keep="error_correction", note="OUT_WAIT = 1 with the multicycle path",
                  power=ss1))
    for name, pos in PIPE_POINTS:
        cuts = cuts_value(pos)
        pw = [("full", "PIPE", dict(CUTS=cuts, GAP=1)), ("gap17", "PIPE", dict(CUTS=cuts, GAP=17))] \
            if name in POWER_PIPES else []
        c.append(dict(name=name, top="cordic_pipe", params=dict(WIDTH=W, ITER=N, CUTS=cuts),
                      sdc="syn/cordic_pipe.sdc", keep=None, note=f"cuts {pos}", power=pw))
    allc = cuts_value(range(NC))
    c.append(dict(name="pipe_nostall", top="cordic_pipe", params=dict(WIDTH=W, ITER=N, CUTS=allc, STALL=0),
                  sdc="syn/cordic_pipe.sdc", keep=None, note="all cuts, no stall support",
                  power=[("full", "PIPE", dict(CUTS=allc, STALL=0, GAP=1)),
                         ("gap17", "PIPE", dict(CUTS=allc, STALL=0, GAP=17))]))
    # one guard bit fewer (G = 4): the fewest that keep rotation and vectoring (all motor control
    # needs) within 2 LSB; divide then misses by 0.2 to 0.5 LSB (python/guard_study.py)
    c.append(dict(name="iter_g4", top="cordic_ss", params=dict(WIDTH=W, ITER=N, G=4), sdc="syn/cordic_ss.sdc",
                  keep="error_correction", note="G = 4 (rotation and vectoring only)",
                  power=[("full", "SS", dict(OUT_WAIT=0, G=4))]))
    r18 = cuts_value(list(range(17)) + [18])
    c.append(dict(name="pipe_r18_g4", top="cordic_pipe", params=dict(WIDTH=W, ITER=N, G=4, CUTS=r18),
                  sdc="syn/cordic_pipe.sdc", keep=None, note="18 ranks, G = 4 (rotation and vectoring only)",
                  power=[("full", "PIPE", dict(CUTS=r18, G=4, GAP=1)), ("gap17", "PIPE", dict(CUTS=r18, G=4, GAP=17))]))
    c.append(dict(name="mult_rot", top="mult_rot", params=dict(WIDTH=W), sdc="compare/mult_rot.sdc",
                  keep=None, files=MULT, note="multiplier-based rotation (comparison)",
                  power=[("full", "MULT", dict(GAP=1)), ("gap17", "MULT", dict(GAP=17))]))
    return c


POWER_PIPES = {"pipe_r18", "pipe_r20"}


# pipeline depths: (name, cut points). 0 = after the input stage, 1..16 = after iteration i - 1,
# 17 = after the x K carry-save tree, 18 = after the x K add, 19 = after rounding (syn/balance.py).
PIPE_POINTS = []


def run(cmd, cwd, log):
    t = time.time()
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    return r.returncode, time.time() - t


def synth(cfg, work, lib, delay_ps):
    os.makedirs(work, exist_ok=True)
    shutil.copy(lib, os.path.join(work, "lib.lib"))
    with open(os.path.join(work, "constr.txt"), "w") as f:
        f.write("set_driving_cell BUF_X2\nset_load 3.0\n")
    g = " ".join(f"-G {k}={v}" for k, v in cfg["params"].items())
    hier = "--best-effort-hierarchy " if cfg["keep"] else ""
    keep = f"setattr -mod -set keep_hierarchy 1 {cfg['keep']}*\n" if cfg["keep"] else ""
    ys = f"""read_slang -j 1 {hier}--top {cfg['top']} {g} {' '.join(cfg.get('files', RTL))}
hierarchy -top {cfg['top']}
{keep}synth -top {cfg['top']} -flatten -noabc
dfflibmap -liberty lib.lib
abc -liberty lib.lib -constr constr.txt -D {delay_ps} -script {ABC_SCRIPT.format(D=delay_ps)}
opt_clean -purge
hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
stat -liberty lib.lib
write_verilog -noattr -noexpr -nohex -nodec netlist_raw.v
"""
    with open(os.path.join(work, "synth.ys"), "w") as f:
        f.write(ys)
    rc, secs = run(["yowasp-yosys", "-q", "-l", "yosys.log", "synth.ys"], work, os.path.join(work, "yosys.out"))
    if rc != 0:
        raise RuntimeError(f"yosys failed for {cfg['name']}, see {work}/yosys.log")
    rename_flops(os.path.join(work, "netlist_raw.v"), os.path.join(work, "netlist.v"))
    return parse_stat(os.path.join(work, "yosys.log"), cfg["top"]), secs


def rename_flops(src, dst):
    """Name every flop after the net on its Q pin, so timing reports show which register a path
    starts and ends at (Yosys leaves them as _12345_)."""
    text = open(src).read()
    used = set()

    def fix(m):
        cell, inst, body = m.group(1), m.group(2), m.group(3)
        q = re.search(r"\.Q\(([^)]*)\)", body)
        if not q:
            return m.group(0)
        base = re.sub(r"[^A-Za-z0-9]+", "_", q.group(1)).strip("_") + "_reg"
        name, k = base, 1
        while name in used:
            k += 1
            name = f"{base}{k}"
        used.add(name)
        return f"{cell} {name} ({body});"
    text = re.sub(r"\b(DFF\w*)\s+(\S+)\s*\((.*?)\);", fix, text, flags=re.S)
    open(dst, "w").write(text)


def parse_stat(log, top):
    s = open(log).read()
    # the last stat block is the whole design (the hierarchy summary when blocks are kept)
    area = re.findall(r"Chip area for (?:top )?module '\\?([^']+)':\s*([\d.]+)", s)
    total = [a for m, a in area if m == top]
    return dict(area=float(total[-1]) if total else float(area[-1][1]))


STA_TCL = r"""
read_liberty lib.lib
read_verilog netlist.v
link_design {top}
set SDC {sdc}
set CLK_PERIOD {target}
source $SDC
puts "=== check_setup"
check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -loops -generated_clocks
puts "=== end"
# fastest clock that meets setup (I/O budgets scale with the period, so bisect)
set lo 0.05
set hi 20.0
for {{set k 0}} {{$k < 16}} {{incr k}} {{
  set CLK_PERIOD [expr {{($lo + $hi) / 2.0}}]
  source $SDC
  if {{[worst_slack -max] >= 0.0}} {{set hi $CLK_PERIOD}} else {{set lo $CLK_PERIOD}}
}}
set CLK_PERIOD $hi
source $SDC
puts "TMIN $hi"
puts "=== critical path at TMIN"
report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3
puts "=== end"
puts "=== endpoints at TMIN"
report_checks -path_delay max -format end -group_path_count 100000 -endpoint_path_count 1 -digits 4
puts "=== end"
set CLK_PERIOD {target}
source $SDC
puts "WNS_TARGET [worst_slack -max]"
puts "WHS_TARGET [worst_slack -min]"
puts "=== tns"
report_tns -digits 4
puts "=== critical path at target"
report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3
puts "=== hold path at target"
report_checks -path_delay min -fields {{slew cap input_pins fanout}} -digits 3
puts "=== design rules"
report_check_types -max_slew -max_capacitance -max_fanout -violators
puts "=== end"
{power}
exit
"""


def sta(cfg, work, sta_bin, target, power_tcl=""):
    sdc = os.path.join(REPO, cfg["sdc"])
    tcl = STA_TCL.format(top=cfg["top"], sdc=sdc, target=target, power=power_tcl)
    with open(os.path.join(work, "sta.tcl"), "w") as f:
        f.write(tcl)
    rc, secs = run([sta_bin, "-no_init", "-no_splash", "-exit", "sta.tcl"], work, os.path.join(work, "sta.log"))
    s = open(os.path.join(work, "sta.log")).read()
    if rc != 0 or "TMIN" not in s:
        raise RuntimeError(f"sta failed for {cfg['name']}, see {work}/sta.log")
    return s, secs


def section(s, name):
    """Lines between '=== name' and the next '=== ' marker line."""
    out, on = [], False
    for line in s.splitlines():
        if line.startswith("=== "):
            if on:
                break
            on = line == "=== " + name
            continue
        if on:
            out.append(line)
    return "\n".join(out)


def path_ends(rep):
    sp = re.search(r"Startpoint: (\S+)", rep)
    ep = re.search(r"Endpoint: (\S+)", rep)
    arr = re.search(r"([\d.-]+)\s+data arrival time", rep)
    return (sp.group(1) if sp else "", ep.group(1) if ep else "", float(arr.group(1)) if arr else None)


def summarize(cfg, stat, s):
    r = dict(name=cfg["name"], top=cfg["top"], note=cfg["note"], area_um2=round(stat["area"], 1))
    r["tmin_ns"] = float(re.search(r"TMIN ([\d.]+)", s).group(1))
    r["fmax_mhz"] = round(1000.0 / r["tmin_ns"], 1)
    r["wns_target_ns"] = float(re.search(r"WNS_TARGET ([-\d.e]+)", s).group(1))
    r["whs_target_ns"] = float(re.search(r"WHS_TARGET ([-\d.e]+)", s).group(1))
    tns = re.search(r"tns max ([-\d.]+)", s)
    r["tns_target_ns"] = float(tns.group(1)) if tns else 0.0
    sp, ep, arr = path_ends(section(s, "critical path at TMIN"))
    r["crit_start"], r["crit_end"], r["crit_arrival_ns"] = sp, ep, arr
    r["check_setup_clean"] = section(s, "check_setup").strip() == ""
    drv = section(s, "design rules").strip()
    r["drv_violations"] = len(re.findall(r"VIOLATED", drv))
    p = re.search(r"^Total\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)", s, re.M)
    if p:
        r["power_internal_mw"], r["power_switching_mw"], r["power_leakage_mw"], r["power_total_mw"] = (
            round(float(x) * 1000, 4) for x in p.groups())
    return r


def count_cells(netlist):
    t = open(netlist).read()
    cells = re.findall(r"^\s+([A-Z][A-Z0-9_]*_X\d+)\s+\S+\s*\(", t, re.M)
    return len(cells), sum(1 for c in cells if c.startswith("DFF"))


POWER_TCL = r"""
read_liberty lib.lib
read_verilog netlist_short.v
link_design {top}
set CLK_PERIOD {target}
source {sdc}
read_vcd -scope tb_power/dut {vcd}
puts "=== annotation"
report_activity_annotation
puts "=== power"
report_power -digits 6
puts "=== end"
exit
"""


def cell_models(out, lib):
    """Verilog models of the library cells, for the gate-level simulation."""
    cells = os.path.join(out, "cells.v")
    if not os.path.exists(cells):
        d = os.path.join(out, "_cells")
        os.makedirs(d, exist_ok=True)
        shutil.copy(lib, os.path.join(d, "lib.lib"))
        run(["yowasp-yosys", "-q", "-p", "read_liberty -ignore_miss_func -ignore_miss_dir lib.lib; "
             "write_verilog -noattr cells.v"], d, os.path.join(d, "yosys.out"))
        shutil.copy(os.path.join(d, "cells.v"), cells)
    return cells


def short_names(src, dst):
    """Give very long escaped net names (deep carry-save trees) short names; Verilator's tracing
    fails on them. The same netlist goes to the simulation and to OpenSTA, so the names match."""
    text = open(src).read()
    names = {}

    def fix(m):
        n = m.group(1)
        if len(n) <= 60:
            return m.group(0)
        names.setdefault(n, f"ln{len(names)}")
        return names[n] + m.group(2)
    open(dst, "w").write(re.sub(r"\\(\S+)(\s)", fix, text))


def power(cfg, work, a, label, define, prm):
    """Gate-level simulation next to the RTL (must match), then OpenSTA power from its activity.
    The simulator is built once per netlist; the load (GAP) is a run option."""
    top = cfg["top"]
    prm = dict(prm)
    gap = prm.pop("GAP", 1)
    bdir = os.path.join(work, "gls")
    exe = os.path.join(bdir, "obj", "Vtb_power")
    short_names(os.path.join(work, "netlist.v"), os.path.join(work, "netlist_short.v"))
    if not os.path.exists(exe):
        os.makedirs(bdir, exist_ok=True)
        net = open(os.path.join(work, "netlist_short.v")).read()
        open(os.path.join(bdir, "netlist_gl.v"), "w").write(
            re.sub(rf"^module {top}\(", f"module {top}_gl(", net, count=1, flags=re.M))
        gs = [f"-GPERIOD={int(round(a.target * 1000))}", "-GCLOCKS=2000"] + [f"-G{k}={v}" for k, v in prm.items()]
        files = [os.path.join(REPO, "syn", "tb_power.sv"), "netlist_gl.v", cell_models(a.out, os.path.abspath(a.lib))] + RTL
        if define == "MULT":
            files += MULT[:2]
        cmd = ["verilator-cli", "--binary", "--trace", "--trace-underscore", "--build-jobs", "2", "-MAKEFLAGS",
               "CFG_CXXFLAGS_PCH_I=-include", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--timing", "-O1",
               "--top-module", "tb_power", f"-D{define}", "-Mdir", "obj"] + gs + files
        rc, _ = run(cmd, bdir, os.path.join(bdir, "build.log"))
        if rc != 0:
            raise RuntimeError(f"gate-level build failed for {cfg['name']}, see {bdir}/build.log")
    vcd = os.path.join(bdir, f"activity_{label}.vcd")
    run([exe, f"+GAP={gap}", f"+VCD={vcd}"], bdir, os.path.join(bdir, f"gls_{label}.log"))
    g = open(os.path.join(bdir, f"gls_{label}.log")).read()
    ops = int(re.search(r"GLS (\d+) operations", g).group(1))
    clocks = int(re.search(r"operations in (\d+) clocks", g).group(1))
    ok = "PASS gate-level netlist matches the RTL" in g
    tcl = POWER_TCL.format(top=top, target=a.target, sdc=os.path.join(REPO, cfg["sdc"]), vcd=vcd)
    with open(os.path.join(work, f"power_{label}.tcl"), "w") as f:
        f.write(tcl)
    run([os.path.abspath(a.sta), "-no_init", "-no_splash", "-exit", f"power_{label}.tcl"], work,
        os.path.join(work, f"power_{label}.log"))
    s = open(os.path.join(work, f"power_{label}.log")).read()
    ann = re.search(r"vcd\s+(\d+)", s)
    unann = re.search(r"unannotated\s+(\d+)", s)
    tot = re.search(r"^Total\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)", s, re.M)
    seq = re.search(r"^Sequential\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)", s, re.M)
    n_ann, n_un = int(ann.group(1)), int(unann.group(1))
    total_w = float(tot.group(4))
    secs = clocks * a.target * 1e-9
    return dict(name=cfg["name"], workload=label, gls="match" if ok else "MISMATCH", ops=ops, clocks=clocks,
                clock_mhz=round(1000 / a.target, 1), annotated_pct=round(100.0 * n_ann / (n_ann + n_un), 1),
                internal_mw=round(float(tot.group(1)) * 1e3, 4), switching_mw=round(float(tot.group(2)) * 1e3, 4),
                leakage_mw=round(float(tot.group(3)) * 1e3, 4), total_mw=round(total_w * 1e3, 4),
                sequential_mw=round(float(seq.group(4)) * 1e3, 4),
                pj_per_op=round(total_w * secs / ops * 1e12, 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--sta", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", type=float, default=1.0, help="target clock period in ns")
    ap.add_argument("--delay", type=int, default=100, help="ABC delay target in ps (small = map for speed)")
    ap.add_argument("--only", default="")
    ap.add_argument("--points", default="", help="JSON list of [name, [cut points]] for the pipeline")
    ap.add_argument("--power", action="store_true", help="gate-level simulation and power")
    ap.add_argument("--reuse", action="store_true", help="keep netlists that are already there")
    a = ap.parse_args()
    global PIPE_POINTS
    if a.points:
        PIPE_POINTS = [(n, p) for n, p in json.loads(open(a.points).read())]
    os.makedirs(a.out, exist_ok=True)
    only = set(x for x in a.only.split(",") if x)
    rows, prows = [], []
    for cfg in configs():
        if only and cfg["name"] not in only:
            continue
        work = os.path.join(a.out, cfg["name"])
        if a.reuse and os.path.exists(os.path.join(work, "netlist.v")):
            stat, t1 = parse_stat(os.path.join(work, "yosys.log"), cfg["top"]), 0.0
        else:
            stat, t1 = synth(cfg, work, os.path.abspath(a.lib), a.delay)
        s, t2 = sta(cfg, work, os.path.abspath(a.sta), a.target)
        r = summarize(cfg, stat, s)
        r["cells"], r["flops"] = count_cells(os.path.join(work, "netlist.v"))
        r["synth_s"], r["sta_s"] = round(t1, 1), round(t2, 1)
        rows.append(r)
        if a.power:
            for label, define, prm in cfg.get("power", []):
                try:
                    pr = power(cfg, work, a, label, define, prm)
                except Exception as e:
                    print(f"   power {label}: FAILED ({e})", flush=True)
                    continue
                prows.append(pr)
                print(f"   power {label:6s} {pr['ops']} ops in {pr['clocks']} clocks, gate-level {pr['gls']}, "
                      f"annotated {pr['annotated_pct']}%: {pr['total_mw']:.3f} mW, {pr['pj_per_op']:.1f} pJ/op", flush=True)
        print(f"{r['name']:16s} area {r['area_um2']:9.1f} um2  cells {r['cells']:6d}  flops {r['flops']:5d}  "
              f"Tmin {r['tmin_ns']:.3f} ns ({r['fmax_mhz']:.0f} MHz)  WNS@{a.target} {r['wns_target_ns']:+.3f}  "
              f"hold {r['whs_target_ns']:+.3f}  crit {r['crit_start']} -> {r['crit_end']}", flush=True)
    # merge with earlier runs in the same folder: a row with the same name (and load) is replaced
    def merge(fname, new, key):
        path = os.path.join(a.out, fname)
        old = json.load(open(path)) if os.path.exists(path) else []
        keys = {key(r) for r in new}
        out = [r for r in old if key(r) not in keys] + new
        with open(path, "w") as f:
            json.dump(out, f, indent=1)
        return out
    allrows = merge("results.json", rows, lambda r: r["name"])
    if prows:
        merge("power.json", prows, lambda r: (r["name"], r["workload"]))
    fields = []
    for r in allrows:
        fields += [k for k in r if k not in fields]
    with open(os.path.join(a.out, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(allrows)


if __name__ == "__main__":
    main()
