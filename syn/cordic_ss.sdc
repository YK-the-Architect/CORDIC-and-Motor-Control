# cordic_ss.sdc : timing constraints for the iterative engine (cordic_ss).
# Plain SDC: works in OpenSTA, Design Compiler and PrimeTime. Times in ns, loads in fF.
# Same clock, I/O budget and design rules as cordic_pipe.sdc, so the two engines are timed
# the same way. With OUT_WAIT = 1, source cordic_ss_mcp.sdc instead.
if {![info exists CLK_PERIOD]} {set CLK_PERIOD 1.00}
if {![info exists IO_SHARE]}   {set IO_SHARE   0.25}
if {![info exists DRIVE_CELL]} {set DRIVE_CELL DFF_X1}
if {![info exists DRIVE_PIN]}  {set DRIVE_PIN  Q}
if {![info exists OUT_LOAD]}   {set OUT_LOAD   3.0}
if {![info exists MAX_TRAN]}   {set MAX_TRAN   0.20}

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty -setup 0.05 [get_clocks clk]
set_clock_uncertainty -hold  0.02 [get_clocks clk]
set_clock_transition 0.04 [get_clocks clk]

set in_ports  [get_ports {rst start mode_cl mode_rv x_in[*] y_in[*] z_in[*]}]
set out_ports [get_ports {out_valid ready x_corr[*] y_corr[*] z[*] ovf}]
set_input_delay  -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $in_ports
set_input_delay  -clock clk -min 0.05 $in_ports
set_driving_cell -lib_cell $DRIVE_CELL -pin $DRIVE_PIN $in_ports
set_output_delay -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $out_ports
set_output_delay -clock clk -min 0.0 $out_ports
set_load $OUT_LOAD $out_ports

set_max_transition $MAX_TRAN [current_design]

# Timing exceptions: none with OUT_WAIT = 0.
# x_corr, y_corr, z and ovf come straight out of the output stage (x K, rounding, saturation),
# which reads the lane registers. With OUT_WAIT = 0 the lanes take their last value one clock
# before out_valid, so that path really has one clock: it is the critical path of this engine.
