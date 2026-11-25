# Synthesis, timing and power

Two ways to get PPA numbers for the engines, with the same constraint files.

| | Open-source flow (numbers in `docs/pipeline_ppa.md`) | Synopsys flow (SJSU lab) |
|---|---|---|
| Synthesis | Yosys (`yowasp-yosys`), NanGate 45 nm | Design Compiler (`dc/run_dc.tcl`) or Fusion Compiler (`fc/run_fc.tcl`), SAED32 |
| Timing | OpenSTA | the tool's own timer, or PrimeTime on the written netlist and SDC |
| Power | OpenSTA with every net's activity from a gate-level simulation (Verilator) | `report_power`, or PrimeTime PX with a VCD from `gls_vcs.sh` |
| Gate-level simulation | zero delay, netlist next to RTL (`tb_power.sv`) | with gate delays from the SDF (`gls_vcs.sh`) |
| Status | run; results in `results/` | written for the lab, not run yet: set the library paths first |

## Constraints

| File | Design |
|---|---|
| `cordic_pipe.sdc` | pipelined engine: clock, I/O delays, driving cell, load, max transition. No exceptions: every path is a real one-clock path. |
| `cordic_ss.sdc` | iterative engine, OUT_WAIT = 0. No exceptions. |
| `cordic_ss_mcp.sdc` | iterative engine, OUT_WAIT = 1: adds the 2-clock multicycle path through the output stage. |

Each file reads `CLK_PERIOD` (default 1.00 ns), `IO_SHARE`, `DRIVE_CELL` (NanGate `DFF_X1`; SAED32 `DFFX1_RVT`), `DRIVE_PIN`, `OUT_LOAD` and `MAX_TRAN`, so the same file serves both libraries. `docs/pipeline_ppa.md` explains each choice and why there are no false paths.

## Open-source flow

```sh
pip install yowasp-yosys            # plus Verilator and an OpenSTA build
python3 syn/run_ppa.py --lib NangateOpenCellLibrary_typical.lib --sta /path/to/sta \
    --out ppa --target 1.25 --points points.json --power
python3 syn/make_tables.py ppa/results.json ppa/power.json 1.25    # the tables in docs/pipeline_ppa.md
python3 syn/plot_sweep.py ppa/results.json docs/pipeline_sweep.png
```

`balance.py` picks the register placement for each pipeline depth (`points.json`). `run_ppa.py --only <names>` runs some design points; `iter_g4` and `pipe_r18_g4` are the one-guard-bit-fewer versions from `python/guard_study.py`.

## Synopsys flow (lab)

```sh
dc_shell -f syn/dc/run_dc.tcl -x "set DESIGN cordic_pipe; set CLK_PERIOD 1.25; set LIB_DIR <SAED32 db folder>"
fc_shell -f syn/fc/run_fc.tcl -x "set DESIGN cordic_pipe; set CLK_PERIOD 1.25; set TECH_FILE <tf>; set NDM_REFS <ndm>"
CELLS=<SAED32 cell models .v> syn/gls_vcs.sh syn/dc/out_cordic_pipe/cordic_pipe_netlist.v \
    syn/dc/out_cordic_pipe/cordic_pipe.sdf cordic_pipe 1400
```

`DESIGN` is `cordic_pipe`, `cordic_ss` or `cordic_ss_mcp`. Reports, netlist, SDF and SDC go to `syn/dc/out_<DESIGN>/` (or `syn/fc/...`). The gate-level script runs the netlist with SDF delays next to the RTL and passes only if every result matches; give it a clock period (ps) above the netlist's fastest clock.
