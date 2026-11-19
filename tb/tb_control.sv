`timescale 1ns/1ps
// tb_control.sv : test group D, control FSM and muxes (W = 16, N = 16)
//   D1  Reset mid-run: rst during EXE        -> IDLE on the next clock, out_valid low, registers cleared
//   D2  Latency: one start pulse             -> out_valid exactly N + 1 clocks later (17 at N = 16)
//   D3  out_valid width                      -> high for exactly one clock
//   D4  Start while busy: start during EXE   -> ignored, result unchanged
//   D5  Start held high for 3 clocks         -> first result correct, then a new run from IDLE
//   D6  Start in the out_valid clock         -> accepted: the next operation runs back to back
//   D7  N not a power of 2: N = 12 and 20    -> exactly N iterations (N - 1 in linear mode)
//   D8  Mode change between runs             -> each correct; mode latched at start
//   D9  Input mux: init = 1, then 0          -> loads the inputs, then feeds back

// D7 helper: latency and a quick result check at another N
module d7_check #(parameter int N = 12) (input logic clk, output int passed, output int failed, output logic done);
  localparam int W = 16;
  logic rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  `include "tb_common.svh"
  initial begin
    int xr, yr, xo, yo, zo, lat_c, lat_l; bit of;
    real ex, ey, ep, tol;
    done = 0;
    reset_dut();
    op(0, 0, q(0.8, QXY), 0, deg2z(30.0), xr, yr, zo, of, lat_c);       // rotation
    ex = 0.8 * $cos(PI / 6) * QXY; ey = 0.8 * $sin(PI / 6) * QXY;
    op(1, 0, q(0.75, QXY), 0, q(0.5, QZL), xo, yo, zo, of, lat_l);      // multiply 0.75 * 0.5
    ep = 0.375 * QXY;
    // N iterations resolve about N - 1 bits: the leftover after the last step is up to
    // |v| * 2^-(N-1), which is 0.8 * 2^(W-N-1) LSB when N < W (6.4 LSB at N = 12)
    tol = 2.0 + ((N < W + 1) ? 0.8 * (2.0 ** (W - N - 1)) : 0.0);
    result("D7", $sformatf("N = %0d: circular %0d clocks, linear %0d", N, lat_c, lat_l),
           lat_c == N + 1 && lat_l == N, $sformatf("(want %0d and %0d)", N + 1, N));
    result("D7", $sformatf("N = %0d: results within %0.1f LSB", N, tol),
           fabs(xr - ex) <= tol && fabs(yr - ey) <= tol && fabs(yo - ep) <= tol,
           $sformatf("rotation %0.2f, %0.2f; multiply %0.2f LSB", xr - ex, yr - ey, yo - ep));
    passed = n_pass; failed = n_fail; done = 1;
  end
endmodule

module tb_control;
  localparam int W = 16, N = 16;
  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;
  `include "tb_common.svh"

  int p12, f12, p20, f20;
  logic d12, d20;
  d7_check #(.N(12)) n12 (.clk, .passed(p12), .failed(f12), .done(d12));
  d7_check #(.N(20)) n20 (.clk, .passed(p20), .failed(f20), .done(d20));

  // rotation of (0.5, 0) by deg, expected outputs in LSBs
  function automatic real rx(real deg); return 0.5 * $cos(deg * PI / 180.0) * QXY; endfunction
  function automatic real ry(real deg); return 0.5 * $sin(deg * PI / 180.0) * QXY; endfunction
  function automatic bit near(int got, real want); return fabs(got - want) <= 2.0; endfunction

  initial begin
    int xo, yo, zo, lat, t, width, n_valid; bit of, ok;
    reset_dut();

    // D1: reset in the middle of a run
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(30.0); start = 1;
    @(negedge clk); start = 0;
    repeat (5) @(negedge clk);
    rst = 1; @(negedge clk); rst = 0;
    ok = (dut.u_control.state == 0) && !out_valid && dut.x == 0 && dut.y == 0 && dut.z_lane == 0;
    n_valid = 0;
    repeat (N + 4) begin @(negedge clk); if (out_valid) n_valid++; end
    result("D1", "rst during EXE: IDLE, out_valid low, cleared", ok && n_valid == 0,
           $sformatf("no out_valid afterwards: %0d", n_valid == 0));

    // D2, D3: latency and out_valid width
    op(0, 0, q(0.5, QXY), 0, deg2z(30.0), xo, yo, zo, of, lat);
    result("D2", "out_valid N + 1 clocks after start", lat == N + 1, $sformatf("%0d clocks", lat));
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(60.0); start = 1;
    @(negedge clk); start = 0; width = 0; t = 0;
    while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    while (out_valid) begin width++; @(negedge clk); end
    result("D3", "out_valid high for exactly one clock", width == 1, $sformatf("%0d clock(s)", width));

    // D4: start pulsed during EXE with other inputs is ignored
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(30.0); start = 1;
    @(negedge clk); start = 0;
    repeat (5) @(negedge clk);
    mode_cl = 1; mode_rv = 1; x_in = q(0.9, QXY); y_in = q(-0.3, QXY); z_in = 0; start = 1;
    @(negedge clk); start = 0;
    t = 0; while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    ok = near(x_corr, rx(30.0)) && near(y_corr, ry(30.0));
    n_valid = 0; repeat (2 * N) begin @(negedge clk); if (out_valid) n_valid++; end
    result("D4", "start during EXE ignored, result unchanged", ok && n_valid == 0,
           $sformatf("extra out_valid: %0d", n_valid));

    // D5: start held for 3 clocks from IDLE
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(-45.0); start = 1;
    repeat (3) @(negedge clk);
    start = 0;
    t = 0; while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    ok = near(x_corr, rx(-45.0)) && near(y_corr, ry(-45.0));
    @(negedge clk);
    ok = ok && (dut.u_control.state == 0);
    op(0, 0, q(0.5, QXY), 0, deg2z(120.0), xo, yo, zo, of, lat);
    result("D5", "start held 3 clocks: first result right, new run ok",
           ok && near(xo, rx(120.0)) && near(yo, ry(120.0)) && lat == N + 1, "");

    // D6: start in the out_valid clock starts the next operation right away
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(10.0); start = 1;
    @(negedge clk); start = 0;
    t = 0; while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    ok = near(x_corr, rx(10.0)) && near(y_corr, ry(10.0));
    mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(-100.0); start = 1;   // in DONE
    @(negedge clk); start = 0; lat = 1;
    while (!out_valid && lat < 4 * N) begin @(negedge clk); lat++; end
    result("D6", "start during DONE: back-to-back run accepted",
           ok && out_valid && near(x_corr, rx(-100.0)) && near(y_corr, ry(-100.0)) && lat == N + 1,
           $sformatf("second result after %0d clocks", lat));
    @(negedge clk);

    // D8: modes change between runs; mode inputs that change mid-run are ignored
    op(0, 0, q(0.5, QXY), 0, deg2z(75.0), xo, yo, zo, of, lat);
    ok = near(xo, rx(75.0)) && near(yo, ry(75.0));
    op(0, 1, q(0.3, QXY), q(0.4, QXY), 0, xo, yo, zo, of, lat);                 // vectoring
    ok = ok && near(xo, 0.5 * QXY) && fabs(wrap_turn(zo - $atan2(0.4, 0.3) / (2 * PI) * TURN)) <= 2.0;
    op(1, 0, q(-0.6, QXY), q(0.1, QXY), q(0.25, QZL), xo, yo, zo, of, lat);     // multiply
    ok = ok && near(yo, (0.1 - 0.6 * 0.25) * QXY);
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(-60.0); start = 1;
    @(negedge clk); start = 0; mode_cl = 1; mode_rv = 1;                         // changed mid-run
    t = 0; while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    ok = ok && near(x_corr, rx(-60.0)) && near(y_corr, ry(-60.0));
    @(negedge clk);
    result("D8", "rotation, vectoring, linear; mode latched at start", ok, "");

    // D9: the input mux loads the inputs on init, then feeds the lanes back
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = q(0.25, QXY); z_in = deg2z(20.0); start = 1;
    @(negedge clk); start = 0;
    ok = (dut.x == (q(0.5, QXY) <<< 5)) && (dut.y == (q(0.25, QXY) <<< 5));   // loaded, G = 5
    @(negedge clk);
    ok = ok && (dut.x != (q(0.5, QXY) <<< 5));                                 // first iteration fed back
    t = 0; while (!out_valid && t < 4 * N) begin @(negedge clk); t++; end
    @(negedge clk);
    result("D9", "init loads the inputs, then the lanes feed back", ok, "");

    wait (d12 && d20);
    $display("DONE: %0d passed, %0d failed", n_pass + p12 + p20, n_fail + f12 + f20);
    $finish;
  end
endmodule
