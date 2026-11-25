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
//   D10 OUT_WAIT = 1 (multicycle output)     -> same results as OUT_WAIT = 0, one clock later; start in HOLD ignored
//   D11 start/ready handshake                -> ready high in IDLE and with out_valid, low while busy; over 3,000
//                                               clocks of random start pulses, a start is taken exactly when ready = 1

// D7 helper: latency and a quick result check at another N
module d7_check #(parameter int N = 12) (input logic clk, output int passed, output int failed, output logic done);
  localparam int W = 16;
  logic rst, start, mode_cl, mode_rv, out_valid, ovf, ready;
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

// D10 helper: an OUT_WAIT = 1 engine and an OUT_WAIT = 0 engine on the same inputs
module d10_check (input logic clk, output int passed, output int failed, output logic done);
  localparam int W = 16, N = 16;
  logic rst, start, mode_cl, mode_rv, out_valid, ovf, ready, ov0, of0;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z, x0, y0, z0;
  cordic_ss #(.WIDTH(W), .ITER(N), .OUT_WAIT(1)) dut (.*);
  cordic_ss #(.WIDTH(W), .ITER(N)) ref0 (.clk, .rst, .x_in, .y_in, .z_in, .start, .mode_cl, .mode_rv,
                                          .out_valid(ov0), .x_corr(x0), .y_corr(y0), .z(z0), .ovf(of0));
  `include "tb_common.svh"
  int r0 [4];
  always @(posedge clk) if (ov0) r0 = '{x0, y0, z0, of0};   // the OUT_WAIT = 0 result
  initial begin
    int xo, yo, zo, lat, bad, badlat; bit of, cl, ok;
    done = 0; bad = 0; badlat = 0;
    reset_dut();
    void'($urandom(10));
    for (int k = 0; k < 2000; k++) begin
      cl = $urandom_range(1);
      op(cl, $urandom_range(1), int'($urandom_range(65535)) - 32768, int'($urandom_range(65535)) - 32768,
         int'($urandom_range(65535)) - 32768, xo, yo, zo, of, lat);
      if (xo != r0[0] || yo != r0[1] || zo != r0[2] || of != r0[3][0]) bad++;
      if (lat != (cl ? N + 1 : N + 2)) badlat++;
    end
    result("D10", "OUT_WAIT = 1: 2,000 results identical, 1 clock later", bad == 0 && badlat == 0,
           $sformatf("%0d different, %0d wrong latency", bad, badlat));
    // start during HOLD is ignored, like start during EXE
    @(negedge clk); mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(40.0); start = 1;
    @(negedge clk); start = 0;
    repeat (N) @(negedge clk);
    ok = dut.u_control.state == 3;                                // HOLD
    mode_cl = 1; mode_rv = 1; x_in = q(0.9, QXY); y_in = q(0.2, QXY); start = 1;
    @(negedge clk); start = 0;
    ok = ok && out_valid && fabs(x_corr - 0.5 * $cos(40.0 * PI / 180.0) * QXY) <= 2.0;
    @(negedge clk);
    ok = ok && !out_valid && dut.u_control.state == 0;
    result("D10", "start in HOLD ignored", ok, "");
    passed = n_pass; failed = n_fail; done = 1;
  end
endmodule

module tb_control;
  localparam int W = 16, N = 16;
  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf, ready;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;
  `include "tb_common.svh"

  int p12, f12, p20, f20;
  logic d12, d20;
  d7_check #(.N(12)) n12 (.clk, .passed(p12), .failed(f12), .done(d12));
  d7_check #(.N(20)) n20 (.clk, .passed(p20), .failed(f20), .done(d20));
  int p10, f10;
  logic d10;
  d10_check w1 (.clk, .passed(p10), .failed(f10), .done(d10));

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

    // D11: ready = 1 exactly when a start would be taken (IDLE, and the out_valid clock)
    @(negedge clk);
    ok = ready && (dut.u_control.state == 0);
    mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(30.0); start = 1;
    @(negedge clk); start = 0; t = 0;
    while (!out_valid && t < 4 * N) begin ok = ok && !ready; @(negedge clk); t++; end
    ok = ok && out_valid && ready;                    // the out_valid clock
    @(negedge clk);
    ok = ok && ready && !out_valid;                   // back in IDLE
    result("D11", "ready high in IDLE and with out_valid, low while busy", ok, "");
    // random start pulses: a start must be taken (FSM re-initializes) exactly when ready = 1
    begin
      int taken_ok, ignored_ok, n_taken, n_ignored; bit s_q, r_q; logic [3:0] i_q; logic [1:0] st_q;
      taken_ok = 1; ignored_ok = 1; n_taken = 0; n_ignored = 0;
      void'($urandom(11));
      repeat (3000) begin
        @(negedge clk);
        start = ($urandom_range(99) < 30);
        mode_cl = $urandom_range(1); mode_rv = $urandom_range(1);
        x_in = int'($urandom_range(65535)) - 32768; y_in = int'($urandom_range(65535)) - 32768; z_in = int'($urandom_range(65535)) - 32768;
        s_q = start; r_q = ready; i_q = dut.u_control.i; st_q = dut.u_control.state;
        @(posedge clk); #1;
        if (s_q && r_q) begin                          // taken: now in EXE, counter at its first value
          n_taken++;
          if (!(dut.u_control.state == 1 && dut.u_control.i == (mode_cl ? 1 : 0))) taken_ok = 0;
        end else if (s_q) begin                        // ignored: the run in progress carries on
          n_ignored++;
          if (st_q == 1 && !(dut.u_control.i == 4'(i_q + 1))) ignored_ok = 0;
          if (st_q == 3 && dut.u_control.state != 2) ignored_ok = 0;
        end
      end
      @(negedge clk); start = 0;
      repeat (N + 3) @(negedge clk);
      result("D11", "random starts: taken exactly when ready = 1", taken_ok && ignored_ok && n_taken > 100 && n_ignored > 100,
             $sformatf("%0d taken, %0d ignored", n_taken, n_ignored));
    end

    wait (d12 && d20 && d10);
    $display("DONE: %0d passed, %0d failed", n_pass + p12 + p20 + p10, n_fail + f12 + f20 + f10);
    $finish;
  end
endmodule
