# Demo and two-minute summary

## Two-minute summary (narrator)

We built a 16-bit fixed-point CORDIC engine for field-oriented motor control and explored its design space. CORDIC computes rotations, vector magnitude and angle, multiply and divide with only shifts, adds and a small angle table. That fits motor control: Park and inverse Park are rotations, and the voltage limit is a vectoring operation.

We built two engines from the same arithmetic. The iterative engine does one iteration per clock: 17 clocks per result in 5,400 square microns. The pipelined engine unrolls the 16 iterations; a register rank can sit at any of 20 cut points, and a valid/ready handshake with a skid buffer lets it stall without losing a result. Both use 2 headroom bits and 5 guard bits, a gain correction built as a carry-save tree, banker's rounding and saturation.

Verification: directed tests for every block, a bit-exact Python model that matches the RTL on 67 million exhaustive operations, a class-based testbench with a scoreboard and coverage, gate-level simulation, and a motor-control loop where both engines run in lockstep and stay within 0.01 rpm of a floating-point controller.

In a 45 nm library the iterative engine tops out at 425 MHz, or 716 MHz with a multicycle path on its output stage. With 18 register ranks the pipeline reaches 912 MHz, meets our 800 MHz target with 0.15 ns of slack, and delivers 36 times the throughput for 4.5 times the area, at a third of the energy per result. Our guard-bit study shows the built design is the smallest that keeps all four operations within 2 LSB; motor control alone can drop one guard bit.

For one motor, the iterative engine is enough. For many channels, the pipeline.

## Demo (video, about 4 minutes)

| # | Show | Command | Say |
|---|---|---|---|
| 1 | Calculator | `python3 python/calculator.py` then `rotate 0.5 0 30`, `vector -0.3 0.4`, `div 0.3 0.8` | The answers are the engine's exact bits (the model matches the RTL bit for bit): the codes in and out, the error against real math in LSBs, and the clocks each engine takes. |
| 2 | Animation | open `docs/cordic_rotate.gif` | After the 180° fold, each iteration turns by ±atan(2^-i) and the angle left about halves: one more bit of the answer per clock. |
| 3 | Regression | `python3 scripts/regress.py --quick` | One line per test group; all pass. |
| 4 | Motor control | `python3 python/foc_sim.py foc.csv --compare docs/foc_rtl.csv` then open `docs/foc.png` | The same loop as the RTL simulation (`tb/tb_foc.sv`), line for line: the speed tracks 3000 rpm, holds under load and reverses; i_d stays at 0; the voltage limit acts at the end of the ramp. |
| 5 | PPA | open `docs/pipeline_sweep.png` | Each register rank shortens the clock until the ×K stage limits it; 18 ranks are the fewest that meet 800 MHz. |

Before recording: run `python3 python/animate_cordic.py` once if the GIF is missing, and have a terminal at the repository root.
