# sta.tcl : static timing analysis of a synthesized netlist with OpenSTA.
# Set LIB, NETLIST, TOP, SDC and CLK_PERIOD before sourcing (syn/run_ppa.py does this).
# Optional: VCD and VCD_SCOPE for power from a gate-level simulation.
read_liberty $LIB
read_verilog $NETLIST
link_design $TOP
source $SDC

puts "=== check_setup"
check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -loops -generated_clocks
puts "=== end check_setup"

puts "=== setup"
report_checks -path_delay max -fields {slew cap input_pins fanout} -digits 3
puts "=== hold"
report_checks -path_delay min -fields {slew cap input_pins fanout} -digits 3
puts "=== summary"
report_worst_slack -max -digits 4
report_worst_slack -min -digits 4
report_tns -digits 4
puts "=== design rules"
report_check_types -max_slew -max_capacitance -max_fanout -violators
puts "=== end design rules"

if {[info exists VCD]} {
  read_vcd -scope $VCD_SCOPE $VCD
}
puts "=== power"
report_power -digits 5
puts "=== end"
