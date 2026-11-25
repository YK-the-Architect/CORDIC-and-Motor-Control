# syn/dc/run_dc.tcl : Synopsys Design Compiler synthesis of the CORDIC engines (SAED32).
# Not run where this was written (no Synopsys tools there): set LIB_DIR for your machine first.
# The open-source flow (syn/run_ppa.py) produced the numbers in docs/pipeline_ppa.md.
#
#   dc_shell -f syn/dc/run_dc.tcl -x "set DESIGN cordic_pipe; set CLK_PERIOD 1.25" | tee dc.log
#   Design Vision: source it from the console after setting the same variables.
# DESIGN: cordic_pipe (default) | cordic_ss | cordic_ss_mcp (cordic_ss with OUT_WAIT = 1)
# Results go to syn/dc/out_<DESIGN>/: netlist, SDF, SDC and reports.

if {![info exists DESIGN]}     {set DESIGN cordic_pipe}
if {![info exists CLK_PERIOD]} {set CLK_PERIOD 1.25}
if {![info exists LIB_DIR]}    {set LIB_DIR /path/to/SAED32_EDK/lib/stdcell_rvt/db_nldm}
if {![info exists LIB_DB]}     {set LIB_DB saed32rvt_tt1p05v25c.db}
set REPO [file normalize [file join [file dirname [info script]] .. ..]]
set OUT  [file join $REPO syn dc out_$DESIGN]
file mkdir $OUT

# libraries
set search_path   [concat . $LIB_DIR $search_path]
set target_library $LIB_DB
set link_library  [list * $LIB_DB]

# RTL
set top $DESIGN
set params "WIDTH=16,ITER=16"
switch $DESIGN {
  cordic_pipe   { set params "WIDTH=16,ITER=16,CUTS=20'h5FFFF" }
  cordic_ss_mcp { set top cordic_ss; set params "WIDTH=16,ITER=16,OUT_WAIT=1" }
}
analyze -format sverilog [glob [file join $REPO rtl *.sv]]
elaborate $top -parameters $params
# elaborate names the design after its parameters (cordic_pipe_WIDTH16_...); give it back its name
set elab [get_object_name [current_design]]
if {$elab ne $top} { rename_design $elab $top }
current_design $top
link
uniquify
check_design > [file join $OUT check_design.rpt]

# constraints: the same SDC files as the open-source flow, with SAED32's flop as the driver
set DRIVE_CELL DFFX1_RVT
set DRIVE_PIN  Q
switch $DESIGN {
  cordic_pipe   { source [file join $REPO syn cordic_pipe.sdc] }
  cordic_ss     { source [file join $REPO syn cordic_ss.sdc] }
  cordic_ss_mcp { source [file join $REPO syn cordic_ss_mcp.sdc] }
}
# the multicycle path needs the output stage kept as its own block (see cordic_ss_mcp.sdc)
if {$DESIGN eq "cordic_ss_mcp"} { set_ungroup [get_cells u_error_correction] false }

# synthesis
compile_ultra -no_autoungroup

# reports
check_timing                                  > [file join $OUT check_timing.rpt]
report_constraint -all_violators              > [file join $OUT violators.rpt]
report_timing -max_paths 10 -nets -transition_time -capacitance > [file join $OUT timing_setup.rpt]
report_timing -delay_type min -max_paths 10   > [file join $OUT timing_hold.rpt]
report_area -hierarchy                        > [file join $OUT area.rpt]
report_power                                  > [file join $OUT power.rpt]
report_qor                                    > [file join $OUT qor.rpt]

# outputs for gate-level simulation (syn/gls_vcs.sh) and for PrimeTime
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output [file join $OUT ${DESIGN}_netlist.v]
write_sdf [file join $OUT ${DESIGN}.sdf]
write_sdc [file join $OUT ${DESIGN}_out.sdc]
puts "done: reports and netlist in $OUT"
exit
