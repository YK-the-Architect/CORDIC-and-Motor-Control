Regression, verilator, 2026-11-21

| Test | Group | What it checks | Result | Checks passed | Checks failed |
|---|---|---|---|---|---|
| A | Shifter | every shift, sign, exhaustive at W = 8 | PASS | 8 | 0 |
| B | Add/sub | random vs integer math, overflow flag | PASS | 7 | 0 |
| C | Output stage | x K, banker's rounding ties, saturation, z wrap | PASS | 14 | 0 |
| U1 | atan table | every entry vs real math, 45 deg, convergence, range | PASS | 12 | 0 |
| U2 | Mux | both inputs, extremes, exhaustive at W = 8 | PASS | 3 | 0 |
| U3 | 2^-i constant | every i, two formats, no wrap past the fraction bits | PASS | 3 | 0 |
| U4 | Lane register | reset, enable, hold, 5,000 random clocks vs a model | PASS | 3 | 0 |
| U5 | Carry-save tree | s + c = sum of inputs: N = 1 to 8, exhaustive at W = 4 | PASS | 9 | 0 |
| U6 | Pipeline rank | register, free-running and wire ranks vs a model, stall | PASS | 4 | 0 |
| U7 | Datapath | every iteration bit for bit vs a model, fold, zero vector, lane_ovf | PASS | 11 | 0 |
| D | Control FSM | reset, latency, start while busy, back to back, OUT_WAIT, ready | PASS | 16 | 0 |
| E | Rotation | key angles, fold edges, every angle at W = 8 | PASS | 11 | 0 |
| F | Vectoring | axes, quadrants, zero vector, random | PASS | 14 | 0 |
| G | Multiply, divide | signs, out of range, divide by zero | PASS | 7 | 0 |
| H | Overflow | type limits, gain growth, underflow, wrap | PASS | 4 | 0 |
| I | Data types | W = 8 to 20 within 2 LSB, bias, N = 8 and 12 | PASS | 26 | 0 |
| J | Pipeline | bit for bit vs cordic_ss: stalls, bubbles, reset, chains, tags | PASS | 9 | 0 |
| J0 | Pipeline, 1 clock | same tests with no internal registers | PASS | 9 | 0 |
| J18 | Pipeline, 18 ranks | same tests at the depth that meets 800 MHz | PASS | 9 | 0 |
| J10 | Pipeline, exhaustive | every input, all 4 modes, W = 8 (67,108,864 operations) | PASS | 1 | 0 |
| K | Motor control | FOC loop: both engines identical, accuracy, speed tracking | PASS | 8 | 0 |
| K4 | Motor control, G = 4 | same loop with one guard bit fewer | PASS | 8 | 0 |
| M | Python model | bit-exact model vs RTL, 413,500 operations | PASS | 1 | 0 |
| M6 | Python model, exhaustive | every input, all 4 modes, W = 6 | PASS | 1 | 0 |
| O | OOP testbench | constrained-random classes, scoreboard, coverage | PASS | 1 | 0 |
| Q | Guard bits | RTL agrees with python/guard_study.py | PASS | 4 | 0 |
| X | Report examples | trace of one rotation, one example per operation | PASS | 6 | 0 |
| S | Sreekara's first testbench | 35 rotation angles within 2 LSB | PASS | 35 | 0 |
| T | Yash's smoke test | random modes, prints only | PASS | 0 | 0 |

All 29 test runs pass. Run again with `python3 scripts/regress.py` (Verilator) or `python3 scripts/regress.py --sim vcs` (VCS, on the lab machines).
