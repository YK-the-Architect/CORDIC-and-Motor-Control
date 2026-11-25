# mult_rot.sdc : constraints for the multiplier-based rotation (comparison only).
# The same clock, I/O budget and design rules as syn/cordic_pipe.sdc, so the two are timed alike.
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

set in_ports  [get_ports {rst in_valid x_in[*] y_in[*] z_in[*]}]
set out_ports [get_ports {out_valid x_out[*] y_out[*]}]
set_input_delay  -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $in_ports
set_input_delay  -clock clk -min 0.05 $in_ports
set_driving_cell -lib_cell $DRIVE_CELL -pin $DRIVE_PIN $in_ports
set_output_delay -clock clk -max [expr {$IO_SHARE * $CLK_PERIOD}] $out_ports
set_output_delay -clock clk -min 0.0 $out_ports
set_load $OUT_LOAD $out_ports

set_max_transition $MAX_TRAN [current_design]
# no timing exceptions: every stage loads every clock
