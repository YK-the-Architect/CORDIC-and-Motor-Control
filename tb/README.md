# Testbenches

One testbench per test group in the verification plan. Each prints one PASS or FAIL line per case and a `DONE:` line at the end. Expected values come from real math in the testbench; errors are in LSBs of the output type.

| File | Group | What it checks |
|---|---|---|
| `tb_shifter.sv` | A | Barrel shifter: no shift, every shift, sign kept, -2.0 and -1, exhaustive at W = 8, shifts above 15 |
| `tb_addsub.sv` | B | Add/sub: random against integer math, overflow flag at both limits, no false alarms |
| `tb_output.sv` | C | Output stage: x K, banker's rounding ties, saturation, z wraps (circular) or saturates (linear) |
| `tb_control.sv` | D | FSM: reset mid-run, latency N + 1, out_valid width, start while busy, start in DONE, N = 12 and 20, mode latching, input mux |
| `tb_rotation.sv` | E | Rotation: key angles, past 90 deg, fold edges, 180 deg, every angle at W = 8, tiny and largest vectors, round trip |
| `tb_vectoring.sv` | F | Vectoring: axes, diagonals, zero vector, long vector, random vectors in all four quadrants |
| `tb_linear.sv` | G | Multiply and divide: signs, z = 0, out of range, divide by zero, negative divisors |
| `tb_overflow.sv` | H | Type limits in every mode, gain growth, small-value underflow, angle wrap |
| `tb_datatypes.sv` | I | W = 8, 12, 16, 20: precision and bias over 100,000 random vectors; N = 8 and 12 |
| `tb_cordic.sv` | | Sreekara's first testbench: 35 rotation angles, now at a 2 LSB tolerance |
| `temp_tb.sv` | | Yash's smoke test: random modes, prints only |

`tb_common.svh` holds the shared driver task and conversions for the system-level testbenches.

## Run

VCS:

```sh
vcs -full64 -sverilog +incdir+tb tb/tb_rotation.sv rtl/*.sv -o simv && ./simv
```

Verilator:

```sh
verilator --binary --timing -Wno-fatal -Itb --top-module tb_rotation tb/tb_rotation.sv rtl/*.sv
./obj_dir/Vtb_rotation
```
