# cordic_ss_mcp.sdc : constraints for the iterative engine built with OUT_WAIT = 1.
# Only valid with OUT_WAIT = 1. With OUT_WAIT = 0 these exceptions would hide real violations.
source [file join [file dirname [info script]] cordic_ss.sdc]

# Multicycle path: the output stage data.
# With OUT_WAIT = 1 the control goes EXE -> HOLD -> DONE. The lane registers take their last
# value at the clock that enters HOLD and keep it through HOLD and DONE (en = 0), and out_valid
# is high only in DONE. Everything that reads the result (the consumer, and ovf_hold through
# sat) samples it only when out_valid is high, so a path from the lane registers through the
# output stage has 2 clocks.
#   -setup 2: check setup at the second clock after launch.
#   -hold 1:  move the hold check back to the launch clock, where a normal one-clock path has it.
# Only the data pins x, y, z of the output stage are listed. Its out_valid and scale_en pins
# come from the FSM and change when DONE starts, so those paths keep one clock.
# The output stage must stay a separate block for these pins to exist: keep its hierarchy
# (Yosys: keep_hierarchy; Design Compiler: no auto-ungroup on u_error_correction).
set mcp_pins [get_pins {u_error_correction/x[*] u_error_correction/y[*] u_error_correction/z[*]}]
set_multicycle_path 2 -setup -through $mcp_pins
set_multicycle_path 1 -hold  -through $mcp_pins
