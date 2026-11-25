# CORDIC-and-Motor-Control
Implementation of the CORDIC engine for fast trigonometric calculations. 

## Where things are

| Folder | What is in it |
|---|---|
| `rtl/` | The engines: `cordic_ss.sv` (iterative, one iteration per clock) and `cordic_pipe.sv` (pipelined, one result per clock), and their blocks |
| `tb/` | Testbenches: one for every RTL module and one per test group, the class-based testbench in `tb/oop/`, the motor-control simulation `tb_foc.sv`, and the report's examples and waveforms (`tb/README.md`) |
| `scripts/` | `regress.py` runs every test in Verilator or VCS and writes a summary; `gen_atan_rom.py` writes the angle table; `make_annexure.py` prints the code listings for the report |
| `python/` | Bit-exact model of the engine, calculator, animation, motor-control simulation and plots, guard-bit study (`python/README.md`) |
| `syn/` | Constraints (SDC), the open-source PPA flow, Design Compiler and Fusion Compiler scripts, gate-level simulation (`syn/README.md`) |
| `compare/` | A multiplier-based rotator, to compare CORDIC with |
| `docs/` | Results: `pipeline_ppa.md` (timing, area, power), `guard_bits.md` (accuracy against guard bits and iterations), `motor_control.md`, `regression.md`, `demo_script.md`, `lab_runs.md` (VCS and Design Compiler steps); figures, including `block_diagram.png` |

## Quick start

```sh
python3 scripts/regress.py               # every test in Verilator (29 runs, about 4 minutes)
python3 scripts/regress.py --sim vcs     # the same in VCS, on the lab machines
```
