#!/bin/bash
# syn/gls_vcs.sh : gate-level simulation with gate delays (SDF) in VCS, for a netlist from
# syn/dc/run_dc.tcl or syn/fc/run_fc.tcl. Runs the netlist next to its RTL on the same
# operations (syn/tb_power.sv) and checks every result matches.
# Not run where this was written (no VCS there): set CELLS to your SAED32 Verilog cell models.
#
#   syn/gls_vcs.sh <netlist.v> <file.sdf> <top: cordic_pipe | cordic_ss> <clock period in ps> [OUT_WAIT]
#   example: syn/gls_vcs.sh syn/dc/out_cordic_pipe/cordic_pipe_netlist.v syn/dc/out_cordic_pipe/cordic_pipe.sdf cordic_pipe 1400
set -e
NET=$1; SDF=$2; TOP=$3; PERIOD=${4:-2000}; OUT_WAIT=${5:-0}
CELLS=${CELLS:-/path/to/SAED32_EDK/lib/stdcell_rvt/verilog/saed32nm.v}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=gls_${TOP}_$(date +%H%M%S)
mkdir -p $WORK && cd $WORK
# the testbench expects the netlist's top module to be called <top>_gl
sed "0,/^module ${TOP}\b/s//module ${TOP}_gl/" "$NET" > netlist_gl.v
case $TOP in
  cordic_pipe) DEF=PIPE; PRM="-pvalue+tb_power.CUTS=20'h5FFFF" ;;
  cordic_ss)   DEF=SS;   PRM="-pvalue+tb_power.OUT_WAIT=$OUT_WAIT" ;;
  *) echo "top must be cordic_pipe or cordic_ss"; exit 1 ;;
esac
vcs -full64 -sverilog -timescale=1ps/1ps +neg_tchk -negdelay +sdfverbose \
    +define+$DEF +define+SDF_FILE=\"$(cd "$(dirname "$SDF")" && pwd)/$(basename "$SDF")\" \
    -pvalue+tb_power.PERIOD=$PERIOD $PRM \
    "$REPO/syn/tb_power.sv" netlist_gl.v "$CELLS" "$REPO"/rtl/*.sv -top tb_power -o simv -l compile.log
./simv +VCD=activity.vcd | tee sim.log
grep -q "PASS gate-level netlist matches the RTL" sim.log && echo "PASS (log: $WORK/sim.log)" || { echo "FAIL (log: $WORK/sim.log)"; exit 1; }
