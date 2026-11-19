# Testbenches

| File | Group | Owner | What it checks |
|---|---|---|---|
| `tb_cordic.sv` | E (start) | Sreekara | Rotation, 35 angles, sin and cos |
| `temp_tb.sv` | | Yash | Smoke test, random modes, prints only |
| `tb_shifter.sv` | A | Sindhura | Barrel shifter: A1 to A7, plus the 23-bit lane width |
| `tb_vectoring.sv` | F | Sindhura | Vectoring: magnitude and angle, F1 to F7 |
| `tb_datatypes.sv` | I | Sindhura | Every word width, precision, bias, fewer iterations (I1 to I4) |

Expected values come from real math in the testbench. Errors are in LSBs of the output type.

## Run

VCS:

```sh
vcs -full64 -sverilog tb/tb_vectoring.sv rtl/*.sv -o simv && ./simv
```

Verilator:

```sh
verilator --binary --timing -Wno-fatal --top-module tb_vectoring tb/tb_vectoring.sv rtl/*.sv
./obj_dir/Vtb_vectoring
```

Each testbench prints one PASS or FAIL line per case and a `DONE:` line at the end.

## Known failures

- F2, F4 at ±135°, F7 quadrants II and III: vectoring with x < 0 needs RTL change 2 (vectoring pre-rotation).
- F5: the zero vector returns the sum of the atan table (99.9°) as its angle; the spec says 0.
