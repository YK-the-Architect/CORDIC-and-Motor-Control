# cordic_pipe.sdc : timing constraints for the pipelined engine (cordic_pipe).
# Plain SDC: works in OpenSTA, Design Compiler and PrimeTime. Times in ns, loads in fF
# (the units of the NanGate 45 nm library; SAED32 uses the same units).
#
# Change any of these by setting the variable before sourcing this file.
if {![info exists CLK_PERIOD]} {set CLK_PERIOD 1.00}     ;# clock period (ns)
if {![info exists IO_SHARE]}   {set IO_SHARE   0.25}     ;# share of the clock used outside the engine
if {![info exists DRIVE_CELL]} {set DRIVE_CELL DFF_X1}   ;# SAED32: DFFX1_RVT
if {![info exists DRIVE_PIN]}  {set DRIVE_PIN  Q}
if {![info exists OUT_LOAD]}   {set OUT_LOAD   3.0}      ;# about 3 flop inputs plus wire
if {![info exists MAX_TRAN]}   {set MAX_TRAN   0.20}     ;# the library's default_max_transition

# Clock. Ideal before clock tree synthesis: uncertainty covers jitter plus the skew the clock
# tree will add, and the transition is a typical clock slew.
create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty -setup 0.05 [get_clocks clk]
set_clock_uncertainty -hold  0.02 [get_clocks clk]
set_clock_transition 0.04 [get_clocks clk]

# Inputs come from flops in the neighbouring block, through a little logic: they arrive IO_SHARE
# of a period after the clock (setup), and no earlier than a flop's clock-to-Q (hold).
# The reset is synchronous, so it is timed like any other input.
set in_ports  [get_ports {rst in_valid mode_cl mode_rv x_in[*] y_in[*] z_in[*] in_tag[*] out_ready}]
set out_ports [get_ports {in_ready out_valid x_corr[*] y_corr[*] z[*] ovf out_tag[*]}]
set_input_delay  -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $in_ports
set_input_delay  -clock clk -min 0.05 $in_ports
set_driving_cell -lib_cell $DRIVE_CELL -pin $DRIVE_PIN $in_ports

# Outputs go to flops in the neighbouring block, through a little logic: they must arrive
# IO_SHARE of a period before the next clock (setup); hold needs nothing extra there.
set_output_delay -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $out_ports
set_output_delay -clock clk -min 0.0 $out_ports
set_load $OUT_LOAD $out_ports

# Design rules
set_max_transition $MAX_TRAN [current_design]

# Timing exceptions: none, on purpose.
# Every register rank loads on every clock the pipeline moves, so every path starts and ends
# on consecutive clocks: there is no multicycle path. Every path is used by some operation:
# there is no false path. The stall enable and the skid buffer are ordinary one-clock paths,
# and in_ready comes from a flop, so there is no combinational path from out_ready to
# in_ready that would need a set_max_delay. See docs/pipeline_ppa.md.
