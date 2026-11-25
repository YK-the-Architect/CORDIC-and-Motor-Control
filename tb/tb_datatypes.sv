`timescale 1ns/1ps
// tb_datatypes.sv : test group I, data types (Sindhura)
//
//   I1  Every word width: W = 8, 12, 16, 20 with N = W. Rotation, vectoring,
//       multiply and divide each stay within 2 LSB at every W.
//   I2  Precision: 100,000 random vectors per configuration, worst error at most 2 LSB.
//   I3  Bias: mean error within +-0.1 LSB on the same vectors.
//   I4  Fewer iterations: W = 16 with N = 8 and N = 12 match the precision chart
//       (about 7 and 11 accurate bits).
//
// Expected values come from real math in the testbench, using the quantized inputs,
// so the error measured is the engine's own. Errors are in LSBs of the output type.
// Vectoring covers all four quadrants and multiply the full z range (RTL changes 1 and 2).

module dt_check #(
  parameter int W = 16,              // word width
  parameter int N = 16,              // iterations
  parameter int G = $clog2(N) + 1,   // guard bits in the engine (same as its default)
  parameter int NVEC = 100000,       // random vectors for rotation and vectoring
  parameter bit CHECK = 1,           // 1: pass/fail on the 2 LSB and 0.1 LSB limits
  parameter real EXP_BITS = 0.0      // I4: expected accurate bits when N < W (0 = not an I4 config)
)(
  input  logic clk,
  output logic done,
  output logic pass
);
  localparam real PI   = 3.14159265358979323846;
  localparam real QXY  = real'(1 << (W - 2));   // x, y: Q2.(W-2)
  localparam real QZL  = real'(1 << (W - 1));   // linear z: Q1.(W-1)
  localparam real TURN = real'(1 << W);         // circular z: 2^W = 360 degrees

  logic rst, start, mode_cl, mode_rv, out_valid, ovf, ready;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;

  cordic_ss #(.WIDTH(W), .ITER(N), .G(G)) dut (.*);

  // ---- helpers ----
  function automatic real urand(real lo, real hi);
    return lo + (hi - lo) * ($urandom() / 4294967296.0);
  endfunction
  function automatic int q(real v, real scale);
    real s; int c;
    s = v * scale;
    c = $rtoi(s + (s >= 0 ? 0.5 : -0.5));
    if (c >  (1 << (W - 1)) - 1) c =  (1 << (W - 1)) - 1;
    if (c < -(1 << (W - 1)))     c = -(1 << (W - 1));
    return c;
  endfunction
  function automatic real wrap_turn(real d);   // angle error into [-TURN/2, TURN/2)
    while (d >=  TURN / 2) d -= TURN;
    while (d <  -TURN / 2) d += TURN;
    return d;
  endfunction
  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction

  // one operation: drive inputs, pulse start, wait for out_valid, sample outputs
  task automatic op(input bit cl, input bit rv, input int xi, input int yi, input int zi,
                    output int xo, output int yo, output int zo);
    int t;
    @(negedge clk);
    mode_cl = cl; mode_rv = rv; x_in = xi; y_in = yi; z_in = zi; start = 1;
    @(negedge clk);
    start = 0; t = 0;
    while (!out_valid && t < 4 * N + 10) begin @(negedge clk); t++; end
    if (!out_valid) $error("W=%0d N=%0d: no out_valid", W, N);
    xo = x_corr; yo = y_corr; zo = z;
    @(negedge clk);
  endtask

  // error statistics for one output
  typedef struct { real worst; real sum; int n; } stat_t;
  function automatic void add(ref stat_t s, input real e);
    if (fabs(e) > s.worst) s.worst = fabs(e);
    s.sum += e; s.n++;
  endfunction

  stat_t rx, ry, vm, va, ml, dv;
  bit ok;

  task automatic report(input string name, input stat_t s, input bit check_bias);
    real mean; bit good;
    mean = s.sum / s.n;
    good = (s.worst <= 2.0) && (!check_bias || fabs(mean) <= 0.1);
    $display("  %-22s worst %6.3f LSB   mean %7.4f LSB   %s", name, s.worst, mean,
             !CHECK ? "(info)" : (good ? "PASS" : "FAIL"));
    if (CHECK && !good) ok = 0;
  endtask

  initial begin
    int xi, yi, zi, xo, yo, zo;
    real x0, y0, th, z0, ex, ey, mag, ang;
    rx = '{0.0, 0.0, 0}; ry = rx; vm = rx; va = rx; ml = rx; dv = rx;
    ok = 1; done = 0; pass = 0;
    void'($urandom(W * 1000 + N * 10 + G));
    rst = 1; start = 0; mode_cl = 0; mode_rv = 0; x_in = 0; y_in = 0; z_in = 0;
    repeat (3) @(negedge clk);
    rst = 0;

    // rotation (circular): any angle, |x|, |y| <= 0.7
    for (int k = 0; k < NVEC; k++) begin
      xi = q(urand(-0.7, 0.7), QXY); yi = q(urand(-0.7, 0.7), QXY);
      zi = int'($urandom() & ((1 << W) - 1)); zi = zi - ((zi >= (1 << (W - 1))) ? (1 << W) : 0);
      x0 = xi / QXY; y0 = yi / QXY; th = zi * 2.0 * PI / TURN;
      op(0, 0, xi, yi, zi, xo, yo, zo);
      ex = x0 * $cos(th) - y0 * $sin(th);
      ey = x0 * $sin(th) + y0 * $cos(th);
      add(rx, xo - ex * QXY);
      add(ry, yo - ey * QXY);
    end

    // vectoring (circular): all four quadrants, |v| >= 0.25 so the angle is defined to an LSB
    for (int k = 0; k < NVEC; k++) begin
      do begin
        xi = q(urand(-0.7, 0.7), QXY); yi = q(urand(-0.7, 0.7), QXY);
        x0 = xi / QXY; y0 = yi / QXY;
      end while ($sqrt(x0 * x0 + y0 * y0) < 0.25);
      op(0, 1, xi, yi, 0, xo, yo, zo);
      mag = $sqrt(x0 * x0 + y0 * y0);
      ang = $atan2(y0, x0) / (2.0 * PI) * TURN;
      add(vm, xo - mag * QXY);
      add(va, wrap_turn(zo - ang));
    end

    // multiply (linear rotation): y = x * z, |x| <= 1, |z| < 0.99
    for (int k = 0; k < NVEC / 4; k++) begin
      xi = q(urand(-1.0, 1.0), QXY); zi = q(urand(-0.99, 0.99), QZL);
      x0 = xi / QXY; z0 = zi / QZL;
      op(1, 0, xi, 0, zi, xo, yo, zo);
      add(ml, yo - x0 * z0 * QXY);
    end

    // divide (linear vectoring): z = y / x, |y / x| < 0.9
    for (int k = 0; k < NVEC / 4; k++) begin
      xi = q(urand(0.5, 1.0), QXY); x0 = xi / QXY;
      yi = q(urand(-0.9, 0.9) * x0, QXY); y0 = yi / QXY;
      op(1, 1, xi, yi, 0, xo, yo, zo);
      add(dv, zo - (y0 / x0) * QZL);
    end

    $display("W = %0d, N = %0d, G = %0d (%0d vectors)%s", W, N, G, NVEC,
             !CHECK ? "  [baseline without the guard bits, for comparison]" : "");
    if (EXP_BITS == 0.0) begin
      report("rotation x",        rx, 1);
      report("rotation y",        ry, 1);
      report("vectoring magnitude", vm, 0);
      report("vectoring angle",   va, 0);
      report("multiply y = x*z",  ml, 0);
      report("divide z = y/x",    dv, 0);
    end else begin
      real worst, bits;
      worst = rx.worst > ry.worst ? rx.worst : ry.worst;
      bits = (W - 2) - $ln(worst) / $ln(2.0);
      $display("  rotation worst %0.1f LSB = %0.2f accurate bits (chart: about %0.0f)   %s",
               worst, bits, EXP_BITS, fabs(bits - EXP_BITS) <= 0.7 ? "PASS" : "FAIL");
      if (fabs(bits - EXP_BITS) > 0.7) ok = 0;
    end
    pass = ok;
    done = 1;
  end
endmodule

module tb_datatypes;
  logic clk = 0;
  always #5 clk = ~clk;

  localparam int NC = 7;
  logic [NC-1:0] done, pass;

  // I1, I2, I3: every word width with N = W
  dt_check #(.W(8),  .N(8))  i8  (.clk, .done(done[0]), .pass(pass[0]));
  dt_check #(.W(12), .N(12)) i12 (.clk, .done(done[1]), .pass(pass[1]));
  dt_check #(.W(16), .N(16)) i16 (.clk, .done(done[2]), .pass(pass[2]));
  dt_check #(.W(20), .N(20)) i20 (.clk, .done(done[3]), .pass(pass[3]));
  // I4: fewer iterations
  dt_check #(.W(16), .N(8),  .EXP_BITS(7.0))  n8  (.clk, .done(done[4]), .pass(pass[4]));
  dt_check #(.W(16), .N(12), .EXP_BITS(11.0)) n12 (.clk, .done(done[5]), .pass(pass[5]));
  // baseline: W = 16, N = 16 without guard bits, to show what they buy (not pass/fail)
  dt_check #(.W(16), .N(16), .G(0), .CHECK(0)) g0 (.clk, .done(done[6]), .pass(pass[6]));

  initial begin
    wait (&done);
    #1;
    $display("DONE: %0d of 6 configurations pass", $countones(pass[5:0]));
    $finish;
  end
endmodule
