`timescale 1ns/1ps
// tb_guard_bits.sv : RTL check of python/guard_study.py (the fewest guard bits and iterations that
// meet the accuracy spec at W = 16).
//
// Runs the group I measurement (dt_check from tb_datatypes.sv: random vectors, errors against real
// math) on the configurations around the answer, and checks the RTL reaches the same verdicts as
// the model:
//   all four operations within 2 LSB:    N = 16, G = 5 (as built) meets; G = 4 and N = 15 do not
//                                        (divide goes past 2 LSB)
//   rotation and vectoring only (motor   G = 4 and N = 15 still meet; G = 2 does not. G = 3 looks
//   control needs nothing else):         fine on random vectors but misses by 0.17 LSB on an
//                                        exhaustive vectoring check (python/guard_study.py), so
//                                        it is left out here: random vectors cannot settle it.
// NVEC = 400,000 per configuration, so even G = 4's rare divide misses (about 2 in 10,000) show up.
//
// Build with Verilator: verilator --binary --timing -Wno-fatal -O3 --top-module tb_guard_bits tb/tb_guard_bits.sv tb/tb_datatypes.sv rtl/*.sv
module tb_guard_bits;
  localparam int NVEC = 400000;
  logic clk = 0;
  always #5 clk = ~clk;
  logic [3:0] done, pass;

  dt_check #(.W(16), .N(16), .G(5), .NVEC(NVEC), .CHECK(0)) c0 (.clk, .done(done[0]), .pass(pass[0]));
  dt_check #(.W(16), .N(16), .G(4), .NVEC(NVEC), .CHECK(0)) c1 (.clk, .done(done[1]), .pass(pass[1]));
  dt_check #(.W(16), .N(15), .G(5), .NVEC(NVEC), .CHECK(0)) c2 (.clk, .done(done[2]), .pass(pass[2]));
  dt_check #(.W(16), .N(16), .G(2), .NVEC(NVEC), .CHECK(0)) c3 (.clk, .done(done[3]), .pass(pass[3]));

  function automatic real mx(real a, real b); return a > b ? a : b; endfunction
  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction
  int bad = 0;

  // verdicts for one configuration: circ = rotation and vectoring meet, all = every operation meets
  `define VERDICT(c, label, exp_all, exp_circ) \
    begin \
      real wc, wa, b; bit all_ok, circ_ok; \
      wc = mx(mx(c.rx.worst, c.ry.worst), mx(c.vm.worst, c.va.worst)); \
      wa = mx(wc, mx(c.ml.worst, c.dv.worst)); \
      b = mx(fabs(c.rx.sum / c.rx.n), fabs(c.ry.sum / c.ry.n)); \
      circ_ok = (wc <= 2.0) && (b <= 0.1); \
      all_ok = circ_ok && (wa <= 2.0); \
      $display("%s %-26s rotation and vectoring %5.2f LSB (%s), all four %5.2f LSB (%s), bias %5.3f", \
               (all_ok == exp_all && circ_ok == exp_circ) ? "PASS" : "FAIL", label, wc, circ_ok ? "meets" : "fails", \
               wa, all_ok ? "meets" : "fails", b); \
      if (all_ok != exp_all || circ_ok != exp_circ) bad++; \
    end

  initial begin
    wait (&done);
    #1;
    $display("Verdicts against the model's (python/guard_study.py):");
    `VERDICT(c0, "N = 16, G = 5 (as built)", 1, 1)
    `VERDICT(c1, "N = 16, G = 4", 0, 1)
    `VERDICT(c2, "N = 15, G = 5", 0, 1)
    `VERDICT(c3, "N = 16, G = 2", 0, 0)
    $display("DONE: %0d of 4 configurations agree with the model", 4 - bad);
    $finish;
  end
endmodule
