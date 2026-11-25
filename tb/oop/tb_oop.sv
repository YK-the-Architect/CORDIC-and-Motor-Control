`timescale 1ns/1ps
// tb/oop/tb_oop.sv : top of the class-based testbench (classes in cordic_pkg.sv).
//
// 50,000 (5,000 in Verilator) constrained-random operations through cordic_pipe (18 ranks) with random input gaps
// (80% of clocks offer an operation) and random output stalls (out_ready 70% of clocks, plus
// long stalls now and then). Each result is checked bit for bit against the class reference
// model, in order and with its tag, and in-range results against real math (2 LSB). A stalled
// result must hold. Coverage bins must all be hit.
//
// Build with Verilator: verilator --binary --timing -Wno-fatal -O3 --top-module tb_oop tb/oop/cordic_if.sv tb/oop/cordic_pkg.sv tb/oop/tb_oop.sv rtl/*.sv
// Build with VCS:       vcs -full64 -sverilog tb/oop/cordic_if.sv tb/oop/cordic_pkg.sv tb/oop/tb_oop.sv rtl/*.sv -top tb_oop && ./simv
// Options: +COUNT=<n> +P_VALID=<percent> +P_READY=<percent> +SEED=<n>
module tb_oop;
  import cordic_pkg::*;
  parameter logic [N + 3 : 0] CUTS = 20'h5FFFF;      // 18 ranks (syn/balance.py)

  logic clk = 0;
  always #5 clk = ~clk;
  cordic_if #(.W(W)) vif (clk);

  cordic_pipe #(.WIDTH(W), .ITER(N), .CUTS(CUTS)) dut (.clk, .rst(vif.rst), .in_valid(vif.in_valid),
      .in_ready(vif.in_ready), .mode_cl(vif.mode_cl), .mode_rv(vif.mode_rv), .x_in(vif.x_in), .y_in(vif.y_in),
      .z_in(vif.z_in), .in_tag(vif.in_tag), .out_valid(vif.out_valid), .out_ready(vif.out_ready),
      .x_corr(vif.x_o), .y_corr(vif.y_o), .z(vif.z_o), .ovf(vif.ovf), .out_tag(vif.out_tag));

  initial begin
    env e;
    bit pass;
`ifdef VERILATOR
    int count = 5000, p_valid = 80, p_ready = 70, seed = 1;   // each randomize() calls z3: about 20 ms
`else
    int count = 50000, p_valid = 80, p_ready = 70, seed = 1;
`endif
    void'($value$plusargs("COUNT=%d", count));
    void'($value$plusargs("P_VALID=%d", p_valid));
    void'($value$plusargs("P_READY=%d", p_ready));
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    vif.rst = 1; vif.in_valid = 0; vif.out_ready = 0; vif.mode_cl = 0; vif.mode_rv = 0;
    vif.x_in = 0; vif.y_in = 0; vif.z_in = 0; vif.in_tag = 0;
    repeat (3) @(negedge clk);
    vif.rst = 0;
    $display("OOP testbench: %0d operations, offered on %0d%% of clocks, out_ready on %0d%%, seed %0d",
             count, p_valid, p_ready, seed);
    e = new(vif, count, p_valid, p_ready);
    e.run(pass);
    $display("DONE: %s", pass ? "PASS" : "FAIL");
    $finish;
  end

  initial begin                                      // a lost result would hang the run
    #(64'd1000 * 10 * 1000000);
    $fatal(1, "timeout");
  end
endmodule
