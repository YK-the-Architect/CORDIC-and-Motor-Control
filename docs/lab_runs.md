# Lab runs: VCS and Design Compiler

The course's ASIC rules ask for simulations in VCS and synthesis in Design Compiler (DC), with PPA analysis. The results in the report so far come from Verilator and from Yosys and OpenSTA. These steps produce the VCS and DC versions on the SJSU lab machines. Each step is one command; the scripts are already in the repository.

## 0. Setup

1. Log in to a lab machine and load the Synopsys tools the way the lab instructions say (the lab's setup script or module command), so that `vcs` and `dc_shell` are on the path.
2. Get the code: `git clone https://github.com/YK-the-Architect/CORDIC-and-Motor-Control.git`, then `git checkout sindhura_dev` once it is pushed (or unzip the code zip).
3. Python 3 with numpy is needed for tests M, M6 and Q. If numpy is missing: `pip3 install --user numpy`.

## 1. VCS regression (every testbench)

```sh
python3 scripts/regress.py --sim vcs --out vcs_run
```

- Expect `29 of 29 tests pass`. The table for the report is `vcs_run/summary.md`; each test's full output is `vcs_run/<test>/run.log`.
- For the report: replace the console output in Section 5.4 with this run's lines, and change "in Verilator" to "in VCS and Verilator" in Sections 2 and 5.
- If a test fails to build, `vcs_run/<test>/compile.log` says why. The OOP testbench (test O) runs 50,000 operations in VCS instead of 5,000.

## 2. Waveforms from VCS (annotated, for the report)

Two ways; either gives Figures 2 and 3 from VCS instead of Verilator.

```sh
# a) same figures as the report, from a VCS dump
vcs -full64 -sverilog -timescale=1ns/1ps tb/tb_waves.sv rtl/*.sv -top tb_waves -o simv_waves
./simv_waves +VCD=waves.vcd               # prints PASS for both engines
python3 python/plot_waves.py waves.vcd docs/

# b) in DVE, to take screenshots
vcs -full64 -sverilog -debug_access+all -timescale=1ns/1ps tb/tb_waves.sv rtl/*.sv -top tb_waves -o simv_dve
./simv_dve -gui
```

In DVE, add these signals and run: `start`, `ready`, `ss_state`, `ss_i`, `ss_z_lane`, `ss_x_lane`, `ss_y_lane`, `out_valid`, `x_corr`, `y_corr` (iterative engine), and `p_in_valid`, `p_in_ready`, `p_in_tag`, `p_out_valid`, `p_out_ready`, `p_skid_full`, `p_out_tag`, `p_x` (pipeline). Show the lanes as signed decimal. Put markers at the start, at out_valid, and at the stall, then annotate the screenshot the way Figures 2 and 3 are annotated.

## 3. Design Compiler (SAED32)

Set `LIB_DIR` to the folder with the SAED32 `.db` files (the lab's SAED32 EDK, `lib/stdcell_rvt/db_nldm`):

```sh
dc_shell -f syn/dc/run_dc.tcl -x "set DESIGN cordic_pipe;   set CLK_PERIOD 1.25; set LIB_DIR <db folder>" | tee dc_pipe.log
dc_shell -f syn/dc/run_dc.tcl -x "set DESIGN cordic_ss;     set CLK_PERIOD 2.50; set LIB_DIR <db folder>" | tee dc_ss.log
dc_shell -f syn/dc/run_dc.tcl -x "set DESIGN cordic_ss_mcp; set CLK_PERIOD 1.50; set LIB_DIR <db folder>" | tee dc_mcp.log
```

Reports go to `syn/dc/out_<DESIGN>/`: `area.rpt`, `timing_setup.rpt`, `timing_hold.rpt`, `power.rpt`, `qor.rpt`, `violators.rpt`, plus the netlist and SDF.

- **Fastest clock:** if `timing_setup.rpt` shows positive slack, run again with a shorter `CLK_PERIOD`; if negative, a longer one. The fastest clock is 1 / (the shortest period with slack >= 0). SAED32 is slower than NanGate 45 nm, so expect lower numbers than the report's.
- **For the report (Section 5.7):** add a table with one row per design: library, clock period, worst setup slack, total cell area (`area.rpt`), total power (`power.rpt`). Keep the NanGate numbers; the design-to-design comparisons should hold in both libraries.
- `cordic_ss_mcp` needs the output stage kept as its own block for the multicycle path; the script already does this.

## 4. Gate-level simulation with SDF delays (optional)

```sh
CELLS=<SAED32 Verilog cell models .v> syn/gls_vcs.sh \
    syn/dc/out_cordic_pipe/cordic_pipe_netlist.v syn/dc/out_cordic_pipe/cordic_pipe.sdf cordic_pipe 2000
```

It runs the netlist with gate delays next to the RTL on the same operations and prints PASS only if every result matches. Use a clock period (ps) above the netlist's fastest clock.

## 5. Checklist

| Step | Output for the report | Done |
|---|---|---|
| VCS regression | `vcs_run/summary.md`, console lines for Section 5.4 | |
| VCS waveforms | Figures 2 and 3 from VCS, or annotated DVE screenshots | |
| DC, 3 designs | area, slack, power table in Section 5.7 | |
| Gate-level with SDF | one PASS line per design (optional) | |
