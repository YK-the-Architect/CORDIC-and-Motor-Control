# syn/fc/run_fc.tcl : Synopsys Fusion Compiler synthesis (compile_fusion to logic_opto) of the
# CORDIC engines with SAED32. Not run where this was written (no Synopsys tools there): set
# TECH_FILE and NDM_REFS for your machine first, and check the command names against your FC
# version's documentation. syn/dc/run_dc.tcl does the same job in Design Compiler.
#
#   fc_shell -f syn/fc/run_fc.tcl -x "set DESIGN cordic_pipe; set CLK_PERIOD 1.25" | tee fc.log
# DESIGN: cordic_pipe (default) | cordic_ss | cordic_ss_mcp (cordic_ss with OUT_WAIT = 1)
# Results go to syn/fc/out_<DESIGN>/.

if {![info exists DESIGN]}     {set DESIGN cordic_pipe}
if {![info exists CLK_PERIOD]} {set CLK_PERIOD 1.25}
if {![info exists TECH_FILE]}  {set TECH_FILE /path/to/SAED32_EDK/tech/milkyway/saed32nm_1p9m_mw.tf}
if {![info exists NDM_REFS]}   {set NDM_REFS [list /path/to/SAED32_EDK/lib/stdcell_rvt/ndm/saed32rvt_c.ndm]}
set REPO [file normalize [file join [file dirname [info script]] .. ..]]
set OUT  [file join $REPO syn fc out_$DESIGN]
file mkdir $OUT

create_lib [file join $OUT ${DESIGN}.nlib] -technology $TECH_FILE -ref_libs $NDM_REFS

set top $DESIGN
set params "WIDTH=16,ITER=16"
switch $DESIGN {
  cordic_pipe   { set params "WIDTH=16,ITER=16,CUTS=20'h5FFFF" }
  cordic_ss_mcp { set top cordic_ss; set params "WIDTH=16,ITER=16,OUT_WAIT=1" }
}
analyze -format sverilog [glob [file join $REPO rtl *.sv]]
elaborate $top -parameters $params
set_top_module $top

set DRIVE_CELL DFFX1_RVT
set DRIVE_PIN  Q
switch $DESIGN {
  cordic_pipe   { source [file join $REPO syn cordic_pipe.sdc] }
  cordic_ss     { source [file join $REPO syn cordic_ss.sdc] }
  cordic_ss_mcp { source [file join $REPO syn cordic_ss_mcp.sdc] }
}
if {$DESIGN eq "cordic_ss_mcp"} { set_ungroup [get_cells u_error_correction] false }

compile_fusion -to logic_opto

report_qor                                  > [file join $OUT qor.rpt]
report_timing -max_paths 10                 > [file join $OUT timing_setup.rpt]
report_timing -delay_type min -max_paths 10 > [file join $OUT timing_hold.rpt]
report_constraints -all_violators           > [file join $OUT violators.rpt]
report_area                                 > [file join $OUT area.rpt]
report_power                                > [file join $OUT power.rpt]

write_verilog [file join $OUT ${DESIGN}_netlist.v]
write_sdf     [file join $OUT ${DESIGN}.sdf]
write_sdc  -output [file join $OUT ${DESIGN}_out.sdc]
save_lib -all
puts "done: reports and netlist in $OUT"
exit
