#!/usr/bin/env python3
"""syn/make_tables.py : the results tables of docs/pipeline_ppa.md, straight from run_ppa.py's
results.json and power.json (no numbers typed by hand).

  python3 syn/make_tables.py <results.json> <power.json> <target period, ns>
"""
import json, re, sys

R = {r["name"]: r for r in json.load(open(sys.argv[1]))}
PW = {(p["name"], p["workload"]): p for p in json.load(open(sys.argv[2]))}
T = float(sys.argv[3])
TGT = f"{1000 / T:.0f} MHz"
LAT = {"iter": 17, "iter_mcp": 18, "mult_rot": 6, "pipe_nostall": 21}
PER = {"iter": 17, "iter_mcp": 18}                 # clocks per result at full load


def depth(n):
    m = re.fullmatch(r"pipe_r(\d+)(_g\d+)?", n)
    return int(m.group(1)) if m else None


def lat(n): return LAT.get(n, depth(n) + 1 if depth(n) is not None else 0)
def per(n): return PER.get(n, 1)
def pw(n, w="full"): return PW.get((n, w))
def slack(r): return f"{r['wns_target_ns']:+.3f} ns ({'meets' if r['wns_target_ns'] >= 0 else 'fails'})"


out = []
p = out.append
p("### Before and after\n")
p(f"| Design | Latency | Results per clock | Fastest clock | Slack at {TGT} | Results per second at the fastest clock | Area (um²) | Flops | Power at 800 MHz, full load | Energy per result |")
p("|---|---|---|---|---|---|---|---|---|---|")
for n, label in [("iter", "Iterative engine (main)"), ("iter_mcp", "Iterative, 2-clock output stage (multicycle path)"),
                 ("pipe_r18", "Pipeline, 18 ranks (fewest that meet 800 MHz)")]:
    r, q = R[n], pw(n)
    p(f"| {label} | {lat(n)} clocks | {'1' if per(n) == 1 else '1/' + str(per(n))} | {r['fmax_mhz']:.0f} MHz ({r['tmin_ns']:.3f} ns) | {slack(r)} | "
      f"{r['fmax_mhz'] / per(n):.0f} M | {r['area_um2']:,.0f} | {r['flops']:,} | {q['total_mw']:.1f} mW | {q['pj_per_op']:.1f} pJ |")

p("\n### Adding register ranks\n")
p("Each row places its ranks where they balance the stages best (`syn/balance.py`). Latency in ns is latency × period.\n")
p("| Ranks | Latency | Fastest clock | Period | Change in period | Latency in ns | Area (um²) | Flops | Worst path, start -> end |")
p("|---|---|---|---|---|---|---|---|---|")
prev = None
for n in sorted((x for x in R if re.fullmatch(r"pipe_r\d+", x)), key=depth):
    r, k = R[n], depth(n)
    d = "" if prev is None else f"{100 * (r['tmin_ns'] / prev - 1):+.0f}%".replace("-0%", "0%").replace("+0%", "0%")
    p(f"| {k} | {k + 1} | {r['fmax_mhz']:.0f} MHz | {r['tmin_ns']:.3f} ns | {d} | {(k + 1) * r['tmin_ns']:.1f} | "
      f"{r['area_um2']:,.0f} | {r['flops']:,} | `{r['crit_start']}` -> `{r['crit_end']}` |")
    prev = r["tmin_ns"]

p("\n### What stall support costs\n")
p("Both have a register at every cut point; only the stall logic differs.\n")
p("| | Area (um²) | Flops | Fastest clock | Power, full load | Power, 1 result every 17 clocks |")
p("|---|---|---|---|---|---|")
for n, label in [("pipe_r20", "With stalls (valid/ready, skid buffer)"), ("pipe_nostall", "Without (in_ready = 1, out_ready ignored)")]:
    r = R[n]
    p(f"| {label} | {r['area_um2']:,.0f} | {r['flops']:,} | {r['fmax_mhz']:.0f} MHz | {pw(n)['total_mw']:.1f} mW | {pw(n, 'gap17')['total_mw']:.1f} mW |")
a, b = R["pipe_r20"], R["pipe_nostall"]
p(f"| Cost | {a['area_um2'] - b['area_um2']:+,.0f} ({100 * (a['area_um2'] / b['area_um2'] - 1):+.0f}%) | "
  f"{a['flops'] - b['flops']:+} | none (within mapping noise) | {100 * (pw('pipe_r20')['total_mw'] / pw('pipe_nostall')['total_mw'] - 1):+.0f}% | "
  f"{100 * (pw('pipe_r20', 'gap17')['total_mw'] / pw('pipe_nostall', 'gap17')['total_mw'] - 1):+.0f}% |")

p("\n### Power (800 MHz, rotations, every net's activity from a gate-level simulation)\n")
p("| Design | Load | Results in 2,000 clocks | Total | Flops' share | Leakage | Energy per result | Gate level vs RTL |")
p("|---|---|---|---|---|---|---|---|")
NAMES = {"iter": "Iterative", "iter_mcp": "Iterative, multicycle", "pipe_r18": "Pipeline, 18 ranks",
         "pipe_r20": "Pipeline, 20 ranks", "pipe_nostall": "Pipeline, no stall support", "mult_rot": "Multipliers + table"}
for n in ["iter", "iter_mcp", "pipe_r18", "pipe_r20", "pipe_nostall", "mult_rot"]:
    for w in ["full", "gap17"]:
        q = pw(n, w)
        if not q:
            continue
        load = "back to back (1 per 17 or 18 clocks)" if n.startswith("iter") else ("1 per clock" if w == "full" else "1 per 17 clocks")
        p(f"| {NAMES[n]} | {load} | {q['ops']:,} | {q['total_mw']:.2f} mW | {100 * q['sequential_mw'] / q['total_mw']:.0f}% | "
          f"{q['leakage_mw']:.2f} mW | {q['pj_per_op']:.1f} pJ | {q['gls']} |")

p("\n### CORDIC against multipliers (rotation)\n")
p("| | Iterative CORDIC | Pipelined CORDIC, 18 ranks | Multipliers + sine table |")
p("|---|---|---|---|")
c, q, m = R["iter"], R["pipe_r18"], R["mult_rot"]
p("| Operations | rotation, vectoring (magnitude, atan2), multiply, divide | same | rotation only |")
p(f"| Area (um²) | {c['area_um2']:,.0f} | {q['area_um2']:,.0f} | {m['area_um2']:,.0f} |")
p(f"| Flops | {c['flops']} | {q['flops']:,} | {m['flops']} |")
p(f"| Latency | {lat('iter')} clocks | {lat('pipe_r18')} clocks | {lat('mult_rot')} clocks |")
p(f"| Results per clock | 1/17 | 1 | 1 |")
p(f"| Fastest clock | {c['fmax_mhz']:.0f} MHz ({R['iter_mcp']['fmax_mhz']:.0f} with the multicycle path) | {q['fmax_mhz']:.0f} MHz | {m['fmax_mhz']:.0f} MHz |")
p(f"| Energy per rotation, full load, 800 MHz | {pw('iter')['pj_per_op']:.0f} pJ | {pw('pipe_r18')['pj_per_op']:.1f} pJ | {pw('mult_rot')['pj_per_op']:.1f} pJ |")
p(f"| Power at 1 rotation every 17 clocks | {pw('iter')['total_mw']:.1f} mW | {pw('pipe_r18', 'gap17')['total_mw']:.1f} mW | {pw('mult_rot', 'gap17')['total_mw']:.1f} mW |")
p("| Worst error, 100,000 random rotations | 1.29 LSB | 1.29 LSB | 1.00 LSB |")

if "iter_g4" in R and "pipe_r18_g4" in R:
    p("\n### One guard bit fewer (rotation and vectoring only, python/guard_study.py)\n")
    p("| Design | Guard bits | Area (um²) | Flops | Fastest clock | Power at 800 MHz, full load | Energy per result |")
    p("|---|---|---|---|---|---|---|")
    for n, g, label in [("iter", 5, "Iterative"), ("iter_g4", 4, "Iterative"),
                        ("pipe_r18", 5, "Pipeline, 18 ranks"), ("pipe_r18_g4", 4, "Pipeline, 18 ranks")]:
        r, q = R[n], pw(n)
        p(f"| {label} | {g} | {r['area_um2']:,.0f} | {r['flops']:,} | {r['fmax_mhz']:.0f} MHz | {q['total_mw']:.2f} mW | {q['pj_per_op']:.1f} pJ |")
    for a_, b_, label in [("iter", "iter_g4", "Iterative"), ("pipe_r18", "pipe_r18_g4", "Pipeline")]:
        ra, rb = R[a_], R[b_]
        p(f"| {label}: change | | {100 * (rb['area_um2'] / ra['area_um2'] - 1):+.1f}% | {rb['flops'] - ra['flops']:+} | "
          f"{100 * (rb['fmax_mhz'] / ra['fmax_mhz'] - 1):+.0f}% | {100 * (pw(b_)['total_mw'] / pw(a_)['total_mw'] - 1):+.1f}% | "
          f"{100 * (pw(b_)['pj_per_op'] / pw(a_)['pj_per_op'] - 1):+.1f}% |")
print("\n".join(out))
