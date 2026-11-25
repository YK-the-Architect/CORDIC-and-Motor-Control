#!/usr/bin/env python3
"""scripts/regress.py : runs every testbench and prints one summary line per test group.

  python3 scripts/regress.py                      Verilator, every test
  python3 scripts/regress.py --sim vcs            Synopsys VCS (the SJSU lab machines)
  python3 scripts/regress.py --quick              skip the long ones (exhaustive W = 8, guard bits)
  python3 scripts/regress.py --only D,J,K         some groups (ids from the table below)
  options: --out <folder> (default regress_<date>_<time>), --list

Each test builds and runs in its own new folder under --out (nothing is deleted). A test passes
when the simulation exits cleanly, prints its DONE line, and prints no FAIL line and no error.
Writes <out>/summary.csv and <out>/summary.md (the table for the report) next to the logs.
"""
import argparse
import csv
import datetime
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = sorted(os.path.join("rtl", f) for f in os.listdir(os.path.join(REPO, "rtl")) if f.endswith(".sv"))

# id, group, what it checks, top module, extra files (besides the top's file and rtl/), parameters,
# long (skipped by --quick), post-run command (run in the test folder; must exit 0)
TESTS = [
    ("A", "Shifter", "every shift, sign, exhaustive at W = 8", "tb_shifter", [], {}, False, None),
    ("B", "Add/sub", "random vs integer math, overflow flag", "tb_addsub", [], {}, False, None),
    ("C", "Output stage", "x K, banker's rounding ties, saturation, z wrap", "tb_output", [], {}, False, None),
    ("U1", "atan table", "every entry vs real math, 45 deg, convergence, range", "tb_atan_rom", [], {}, False, None),
    ("U2", "Mux", "both inputs, extremes, exhaustive at W = 8", "tb_mux", [], {}, False, None),
    ("U3", "2^-i constant", "every i, two formats, no wrap past the fraction bits", "tb_one_shifted", [], {}, False, None),
    ("U4", "Lane register", "reset, enable, hold, 5,000 random clocks vs a model", "tb_sync_reg", [], {}, False, None),
    ("U5", "Carry-save tree", "s + c = sum of inputs: N = 1 to 8, exhaustive at W = 4", "tb_csa_tree", [], {}, False, None),
    ("U6", "Pipeline rank", "register, free-running and wire ranks vs a model, stall", "tb_pipe_cut", [], {}, False, None),
    ("U7", "Datapath", "every iteration bit for bit vs a model, fold, zero vector, lane_ovf", "tb_datapath", [], {}, False, None),
    ("D", "Control FSM", "reset, latency, start while busy, back to back, OUT_WAIT, ready", "tb_control", [], {}, False, None),
    ("E", "Rotation", "key angles, fold edges, every angle at W = 8", "tb_rotation", [], {}, False, None),
    ("F", "Vectoring", "axes, quadrants, zero vector, random", "tb_vectoring", [], {}, False, None),
    ("G", "Multiply, divide", "signs, out of range, divide by zero", "tb_linear", [], {}, False, None),
    ("H", "Overflow", "type limits, gain growth, underflow, wrap", "tb_overflow", [], {}, False, None),
    ("I", "Data types", "W = 8 to 20 within 2 LSB, bias, N = 8 and 12", "tb_datatypes", [], {}, False, None),
    ("J", "Pipeline", "bit for bit vs cordic_ss: stalls, bubbles, reset, chains, tags", "tb_pipeline", [], {}, False, None),
    ("J0", "Pipeline, 1 clock", "same tests with no internal registers", "tb_pipeline", [], {"CUTS": "20'h00000"}, False, None),
    ("J18", "Pipeline, 18 ranks", "same tests at the depth that meets 800 MHz", "tb_pipeline", [], {"CUTS": "20'h5FFFF"}, False, None),
    ("J10", "Pipeline, exhaustive", "every input, all 4 modes, W = 8 (67,108,864 operations)", "tb_pipe_exhaustive", [], {}, True, None),
    ("K", "Motor control", "FOC loop: both engines identical, accuracy, speed tracking", "tb_foc", [], {}, False, None),
    ("K4", "Motor control, G = 4", "same loop with one guard bit fewer", "tb_foc", [], {"G": "4"}, False, None),
    ("M", "Python model", "bit-exact model vs RTL, 413,500 operations", "tb_model_vectors", [], {},
     False, [sys.executable, os.path.join(REPO, "python", "check_model.py"), "model_vectors.txt"]),
    ("M6", "Python model, exhaustive", "every input, all 4 modes, W = 6", "tb_model_vectors", [],
     {"W": "6", "N": "6", "EXH": "1"}, False,
     [sys.executable, os.path.join(REPO, "python", "check_model.py"), "model_vectors.txt"]),
    ("O", "OOP testbench", "constrained-random classes, scoreboard, coverage", "tb_oop", ["tb/oop/cordic_if.sv", "tb/oop/cordic_pkg.sv"], {}, False, None),
    ("Q", "Guard bits", "RTL agrees with python/guard_study.py", "tb_guard_bits", ["tb/tb_datatypes.sv"], {}, True, None),
    ("X", "Report examples", "trace of one rotation, one example per operation", "tb_examples", [], {}, False, None),
    ("S", "Sreekara's first testbench", "35 rotation angles within 2 LSB", "tb_cordic", [], {}, False, None),
    ("T", "Yash's smoke test", "random modes, prints only", "temp_tb", [], {}, False, None),
]


def top_file(top):
    for d in ("tb", os.path.join("tb", "oop")):
        p = os.path.join(d, top + ".sv")
        if os.path.exists(os.path.join(REPO, p)):
            return p
    raise FileNotFoundError(top)


def build_cmd(sim, top, files, params, work):
    src = [os.path.join(REPO, f) for f in files]
    if sim == "verilator":
        exe = shutil.which("verilator") or shutil.which("verilator-cli") or "verilator"
        # -MAKEFLAGS: some Verilator installs race on the precompiled header with parallel make
        return ([exe, "--binary", "--timing", "-O3", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--build-jobs", "2",
                 "-MAKEFLAGS", "CFG_CXXFLAGS_PCH_I=-include",
                 "-I" + os.path.join(REPO, "tb"), "--top-module", top, "-Mdir", "obj"] +
                [f"-G{k}={v}" for k, v in params.items()] + src), [os.path.join(work, "obj", "V" + top)]
    # VCS: -pvalue overrides top-level parameters at compile time
    return (["vcs", "-full64", "-sverilog", "-timescale=1ns/1ps", "+incdir+" + os.path.join(REPO, "tb"),
             "-top", top, "-o", "simv", "-l", "compile.log"] +
            [f"-pvalue+{top}.{k}={v}" for k, v in params.items()] + src), [os.path.join(work, "simv")]


def judge(text, rc):
    """(passed, checks passed, checks failed, note) from a simulation log."""
    lines = text.splitlines()
    fails = [l for l in lines if re.search(r"\bFAIL\b", l)]
    errors = [l for l in lines if re.search(r"%Error|Error-\[|\bError:|\$fatal|Fatal:|Assertion failed", l)]
    done = [l for l in lines if l.startswith("DONE")]
    n_pass = sum(1 for l in lines if re.search(r"\bPASS\b", l))
    ok = rc == 0 and not fails and not errors and (bool(done) or "$finish" in text)
    note = (fails or errors or done or [""])[0].strip()
    return ok, n_pass, len(fails), note


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", choices=["verilator", "vcs"], default="verilator")
    ap.add_argument("--only", default="")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per run")
    a = ap.parse_args()
    if a.list:
        for t in TESTS:
            print(f"{t[0]:4s} {t[1]:26s} {t[2]}{'  (long)' if t[6] else ''}")
        return 0
    only = {x.strip() for x in a.only.split(",") if x.strip()}
    out = os.path.abspath(a.out or "regress_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    os.makedirs(out, exist_ok=True)
    rows = []
    for tid, group, what, top, extra, params, long_, post in TESTS:
        if (only and tid not in only) or (a.quick and long_ and not only):
            continue
        work = os.path.join(out, tid)
        os.makedirs(work, exist_ok=True)
        files = extra + [top_file(top)] + RTL      # packages first
        cmd, run_cmd = build_cmd(a.sim, top, files, params, work)
        t0 = time.time()
        with open(os.path.join(work, "build.log"), "w") as f:
            rc = subprocess.run(cmd, cwd=work, stdout=f, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            rows.append(dict(id=tid, group=group, checks=what, result="BUILD FAILED", passed=0, failed=0,
                             seconds=round(time.time() - t0), note="see build.log", log=os.path.join(work, "build.log")))
            print(f"{tid:4s} {group:26s} BUILD FAILED  ({work}/build.log)", flush=True)
            continue
        t1 = time.time()
        try:
            r = subprocess.run(run_cmd, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               timeout=a.timeout)
            text, rc = r.stdout, r.returncode
        except subprocess.TimeoutExpired as e:
            text, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), -1
            text += "\nFAIL: timeout\n"
        if post and rc == 0:
            p = subprocess.run(post, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            text += "\n" + p.stdout
            rc = p.returncode
        open(os.path.join(work, "run.log"), "w").write(text)
        ok, n_pass, n_fail, note = judge(text, rc)
        secs = round(time.time() - t1)
        rows.append(dict(id=tid, group=group, checks=what, result="PASS" if ok else "FAIL", passed=n_pass,
                         failed=n_fail, seconds=secs, note=note, log=os.path.join(work, "run.log")))
        # one short line per test; on a failure, also the first failing line of the log (all of it is in run.log)
        print(f"{tid:4s} {group:26s} {'PASS' if ok else 'FAIL':5s} {n_pass:4d} checks passed, {n_fail} failed  "
              f"({secs} s)" + ("" if ok else f"  {note[:70]}"), flush=True)

    with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["id"])
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(f"Regression, {a.sim}, {datetime.date.today()}\n\n")
        f.write("| Test | Group | What it checks | Result | Checks passed | Checks failed |\n|---|---|---|---|---|---|\n")
        for r in rows:
            f.write(f"| {r['id']} | {r['group']} | {r['checks']} | {r['result']} | {r['passed']} | {r['failed']} |\n")
    n_ok = sum(r["result"] == "PASS" for r in rows)
    print(f"\n{n_ok} of {len(rows)} tests pass. Summary: {out}/summary.md")
    return 0 if n_ok == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
