# Testbenches

One testbench per test group in the verification plan, and every RTL module has at least one testbench of its own (table below). Each prints one PASS or FAIL line per case and a `DONE:` line at the end. Expected values come from real math in the testbench; errors are in LSBs of the output type.

| File | Group | What it checks |
|---|---|---|
| `tb_shifter.sv` | A | Barrel shifter: no shift, every shift, sign kept, -2.0 and -1, exhaustive at W = 8, shifts above 15 |
| `tb_addsub.sv` | B | Add/sub: random against integer math, overflow flag at both limits, no false alarms |
| `tb_output.sv` | C | Output stage: x K, banker's rounding ties, saturation, z wraps (circular) or saturates (linear) |
| `tb_atan_rom.sv` | U1 | atan(2^-i) table at three sizes: every entry within 0.5 LSB of real math, 45 deg exactly, never increasing, convergence condition, range above 90 deg |
| `tb_mux.sv` | U2 | 2-to-1 mux: random pairs at the lane width, extremes keep their sign, exhaustive at W = 8 |
| `tb_one_shifted.sv` | U3 | 2^-i constant: every i in the lane format and the default format, 0 (not a wrap) past the fraction bits |
| `tb_sync_reg.sv` | U4 | Lane register: reset wins over enable, hold, load, 5,000 random clocks against a model |
| `tb_csa_tree.sv` | U5 | Carry-save tree: s + c equals the sum for N = 1 to 5 and 8 (the size x K uses), exhaustive at W = 4, extreme patterns |
| `tb_pipe_cut.sv` | U6 | Pipeline rank: registered with and without stall support, and as a wire, against a model; a 10-clock stall |
| `tb_datapath.sv` | U7 | Datapath alone, driven like the control unit: init and fold, every iteration bit for bit against a model in all 4 modes, results vs real math, zero vector, lane overflow flag |
| `tb_control.sv` | D | FSM: reset mid-run, latency N + 1, out_valid width, start while busy, start in DONE, N = 12 and 20, mode latching, input mux, OUT_WAIT = 1 (same results one clock later), start/ready handshake (D11) |
| `tb_rotation.sv` | E | Rotation: key angles, past 90 deg, fold edges, 180 deg, every angle at W = 8, tiny and largest vectors, round trip |
| `tb_vectoring.sv` | F | Vectoring: axes, diagonals, zero vector, long vector, random vectors in all four quadrants |
| `tb_linear.sv` | G | Multiply and divide: signs, z = 0, out of range, divide by zero, negative divisors |
| `tb_overflow.sv` | H | Type limits in every mode, gain growth, small-value underflow, angle wrap |
| `tb_datatypes.sv` | I | W = 8, 12, 16, 20: precision and bias over 100,000 random vectors; N = 8 and 12 |
| `tb_pipeline.sv` | J1-J9 | Pipelined engine against `cordic_ss`, bit for bit: random and corner inputs, latency and one result per clock, bubbles and stalls, a stalled result holds, long stall, reset in flight, dependent chains, tags. Any depth with `-GCUTS=` |
| `tb_pipe_exhaustive.sv` | J10 | Every input in all 4 modes at W = 8 (67,108,864 operations), bit for bit against `cordic_ss` |
| `tb_foc.sv` | K | Motor control (FOC) with both engines in the loop: identical results, accuracy, speed tracking, against a floating-point loop (`docs/motor_control.md`) |
| `tb_model_vectors.sv` | M | Dumps RTL results for `python/check_model.py` (bit-exact model check); `-GEXH=1` covers every input at small W |
| `oop/` | O | Class-based testbench: transaction, generator, driver, sink, monitor, scoreboard with a bit-exact reference model, coverage bins, random stalls |
| `tb_guard_bits.sv` | Q | RTL check of `python/guard_study.py`'s verdicts (fewest guard bits and iterations) |
| `tb_examples.sv` | X | The report's worked examples: a clock-by-clock trace of one rotation, and one example of each operation against real math |
| `tb_waves.sv` | | Dumps the waveforms of the report (iterative engine back to back, pipeline through a stall) and checks them; `python/plot_waves.py` draws them |
| `tb_cordic.sv` | | Sreekara's first testbench: 35 rotation angles, now at a 2 LSB tolerance |
| `temp_tb.sv` | | Yash's smoke test: random modes, prints only |

`tb_common.svh` holds the shared driver task and conversions for the system-level testbenches.

`compare/tb_mult_rot.sv` checks the multiplier-based rotation used for the comparison in `docs/pipeline_ppa.md`, and `syn/tb_power.sv` runs synthesized netlists next to their RTL (gate-level check and power).

## Run

Everything, with one summary line per group (`--sim vcs` on the lab machines, `--quick` skips the long runs, `--list` shows the ids):

```sh
python3 scripts/regress.py
python3 scripts/regress.py --sim vcs --only D,J,K
```

It writes `summary.csv` and `summary.md` next to the logs. One test by hand:

VCS:

```sh
vcs -full64 -sverilog +incdir+tb tb/tb_rotation.sv rtl/*.sv -o simv && ./simv
```

Verilator:

```sh
verilator --binary --timing -Wno-fatal -Itb --top-module tb_rotation tb/tb_rotation.sv rtl/*.sv
./obj_dir/Vtb_rotation
```

The pipeline tests at another depth (here 1 clock, no internal registers), and the exhaustive test:

```sh
verilator --binary --timing -Wno-fatal -Itb --top-module tb_pipeline -GCUTS=20\'h00000 tb/tb_pipeline.sv rtl/*.sv
verilator --binary --timing -Wno-fatal -O3 --top-module tb_pipe_exhaustive tb/tb_pipe_exhaustive.sv rtl/*.sv
```
