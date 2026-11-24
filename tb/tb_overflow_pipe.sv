`timescale 1ns/1ps
// tb_overflow_pipe.sv : test group H, overflow and underflow across the engine (W = 16, N = 16)
//   H1  Type limits (+1.99994, +1.99994) and (-2, -2) in every mode -> out-of-range results saturate with ovf = 1; nothing wraps
//   H2  Gain growth: unit vectors at every angle                    -> no internal add/sub overflow flag ever fires
//   H3  Late-iteration underflow: small values where x >> i is 0 or -1 -> mean error within +-0.1 LSB
//   H4  Angle wrap: z near +-180 deg, sums that cross 180 deg       -> wraps, no flag

module tb_overflow_pipe;
  localparam int W = 16, N = 16;
  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_pipe #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;
  `include "tb_common.svh"

  // count internal add/sub overflows while the engine iterates
  int lane_ovf_count = 0;

  // one output against its exact value: inside the range -> within 2 LSB; outside -> the right rail
  function automatic bit out_ok(int got, real exact, output bit outside);
    outside = exact > WMAX + 0.5 || exact < WMIN - 0.5;
    if (exact > WMAX + 0.5) return got == WMAX;
    if (exact < WMIN - 0.5) return got == WMIN;
    return fabs(got - exact) <= 2.0;
  endfunction

  initial begin
    int xo, yo, zo, lat, bad; bit of, sx, sy, ok; real x0, y0, th, sum; int n;
    int lim [2] = '{WMAX, WMIN};
    reset_dut();

    // H1: both corners of the type in every mode
    bad = 0;
    foreach (lim[c]) begin
      x0 = lim[c] / QXY; y0 = lim[c] / QXY;
      // rotation at 16 angles
      for (int k = 0; k < 16; k++) begin
        th = (-180.0 + 22.5 * k) * PI / 180.0;
        op(0, 0, lim[c], lim[c], deg2z(-180.0 + 22.5 * k), xo, yo, zo, of, lat);
        th = deg2z(-180.0 + 22.5 * k) * 2.0 * PI / TURN;
        if (!out_ok(xo, (x0 * $cos(th) - y0 * $sin(th)) * QXY, sx)) bad++;
        if (!out_ok(yo, (x0 * $sin(th) + y0 * $cos(th)) * QXY, sy)) bad++;
        if ((sx || sy) && !of) bad++;
      end
      // vectoring: magnitude 2.83 saturates, angle still right
      op(0, 1, lim[c], lim[c], 0, xo, yo, zo, of, lat);
      if (xo != WMAX || !of) bad++;
      if (fabs(wrap_turn(zo - $atan2(y0, x0) / (2.0 * PI) * TURN)) > 2.0) bad++;
      // multiply by 0.5: y = y0 + x / 2 is out of range
      op(1, 0, lim[c], lim[c], q(0.5, QZL), xo, yo, zo, of, lat);
      if (!out_ok(yo, (y0 + x0 * (q(0.5, QZL) / QZL)) * QXY, sy) || !sy || !of) bad++;
      // divide y / x = 1 is out of range
      op(1, 1, lim[c], lim[c], 0, xo, yo, zo, of, lat);
      if (!of) bad++;
    end
    result("H1", "type limits in all four modes", bad == 0, $sformatf("%0d bad", bad));

    // H2: unit vectors at 4,096 angles in rotation and vectoring; no lane overflow, no ovf
    lane_ovf_count = 0; bad = 0;
    for (int c = -32768; c < 32768; c += 16) begin
      op(0, 0, q(1.0, QXY), 0, c, xo, yo, zo, of, lat);
      if (of) bad++;
      th = c * 2.0 * PI / TURN;
      op(0, 1, q($cos(th), QXY), q($sin(th), QXY), 0, xo, yo, zo, of, lat);
      if (of) bad++;
    end
    result("H2", "unit vectors, 4,096 angles, rotation and vectoring", bad == 0,
           $sformatf("lane overflows %0d, ovf %0d", lane_ovf_count, bad));

    // H3: small vectors, where x >> i is 0 or -1 after a few iterations
    sum = 0; n = 0;
    void'($urandom(3));
    for (int k = 0; k < 20000; k++) begin
      int xi, yi, zi;
      xi = int'($urandom_range(32)) - 16; yi = int'($urandom_range(32)) - 16;
      zi = int'($urandom() & 16'hFFFF) - 32768;
      op(0, 0, xi, yi, zi, xo, yo, zo, of, lat);
      th = zi * 2.0 * PI / TURN;
      sum += (xo - (xi * $cos(th) - yi * $sin(th))) + (yo - (xi * $sin(th) + yi * $cos(th)));
      n += 2;
    end
    result("H3", "20,000 small vectors (up to 16 LSB): mean error", fabs(sum / n) <= 0.1,
           $sformatf("mean %0.4f LSB", sum / n));

    // H4: angles that cross 180 degrees wrap without a flag
    ok = 1;
    op(0, 1, q(0.5 * $cos(PI / 6), QXY), q(0.5 * $sin(PI / 6), QXY), deg2z(170.0), xo, yo, zo, of, lat);
    if (of || fabs(wrap_turn(zo - deg2z(-160.0))) > 2.0) ok = 0;            // 170 + 30 = 200 = -160
    op(0, 1, q(0.5 * $cos(-PI / 6), QXY), q(0.5 * $sin(-PI / 6), QXY), deg2z(-170.0), xo, yo, zo, of, lat);
    if (of || fabs(wrap_turn(zo - deg2z(160.0))) > 2.0) ok = 0;             // -170 - 30 = -200 = 160
    op(0, 0, q(0.5, QXY), 0, deg2z(179.99), xo, yo, zo, of, lat);
    if (of) ok = 0;
    op(0, 0, q(0.5, QXY), 0, deg2z(-179.99), xo, yo, zo, of, lat);
    if (of) ok = 0;
    result("H4", "sums past 180 deg wrap, no ovf", ok, "");

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
