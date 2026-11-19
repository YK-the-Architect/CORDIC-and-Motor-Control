`timescale 1ns/1ps
// tb_rotation.sv : test group E, rotation in circular mode: sin/cos, Park and inverse Park
// W = 16, N = 16 (E6 uses W = 8, N = 8). Errors in LSBs of x and y (Q2.14 at W = 16).
//   E1  Key angles 0, +-30, +-45, +-90, +-135, 180 deg   -> within 2 LSB
//   E2  Past +-90 deg: 91 to 179 and -91 to -179         -> within 2 LSB
//   E3  Quadrant edges: +-1 LSB around +-90 and 180 deg  -> no jump across the fold
//   E4  +180 and -180 deg: z = -32768                     -> one code, one answer: (-x, -y)
//   E5  Smallest angle: z = +-1 LSB (0.0055 deg)          -> output nearly equals input
//   E6  Every angle: W = 8, all 256 angle codes           -> within 2 LSB
//   E7  Zero vector (0, 0), any angle                     -> (0, 0) exactly
//   E8  Tiny vectors (underflow): length 1 to 4 LSB       -> within 2 LSB, mean error near 0
//   E9  Unit vector at every angle                        -> within 2 LSB, no saturation
//   E10 Largest input (1.99, 1.99) at every angle         -> out-of-range results saturate, ovf = 1, nothing wraps
//   E11 Round trip: rotate by theta, then by -theta       -> back to the input within 4 LSB

module e6_check (input logic clk, output int passed, output int failed, output logic done);
  localparam int W = 8, N = 8;
  logic rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  `include "tb_common.svh"
  initial begin
    int xo, yo, zo, lat, bad; bit of; real th, x0, y0, worst;
    done = 0; bad = 0; worst = 0;
    reset_dut();
    x0 = q(0.7, QXY) / QXY; y0 = q(0.2, QXY) / QXY;
    for (int c = -128; c < 128; c++) begin
      real ex, ey;
      op(0, 0, q(0.7, QXY), q(0.2, QXY), c, xo, yo, zo, of, lat);
      th = c * 2.0 * PI / TURN;
      ex = (x0 * $cos(th) - y0 * $sin(th)) * QXY; ey = (x0 * $sin(th) + y0 * $cos(th)) * QXY;
      if (fabs(xo - ex) > worst) worst = fabs(xo - ex);
      if (fabs(yo - ey) > worst) worst = fabs(yo - ey);
      if (fabs(xo - ex) > 2.0 || fabs(yo - ey) > 2.0) bad++;
    end
    result("E6", "W = 8: all 256 angle codes", bad == 0, $sformatf("worst %0.2f LSB", worst));
    passed = n_pass; failed = n_fail; done = 1;
  end
endmodule

module tb_rotation;
  localparam int W = 16, N = 16;
  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;
  `include "tb_common.svh"

  int p8, f8; logic d8;
  e6_check e6 (.clk, .passed(p8), .failed(f8), .done(d8));

  // rotate codes (xi, yi) by angle code zi; errors in LSBs against real math
  task automatic rot(input int xi, input int yi, input int zi,
                     output real ex, output real ey, output int xo, output int yo, output bit of);
    int zo, lat; real x0, y0, th;
    op(0, 0, xi, yi, zi, xo, yo, zo, of, lat);
    x0 = xi / QXY; y0 = yi / QXY; th = zi * 2.0 * PI / TURN;
    ex = (x0 * $cos(th) - y0 * $sin(th)) * QXY;
    ey = (x0 * $sin(th) + y0 * $cos(th)) * QXY;
  endtask

  // run a list of angle codes on one input; returns the worst error
  task automatic sweep(input int xi, input int yi, input int codes [$], output real worst, output int bad);
    real ex, ey; int xo, yo; bit of;
    worst = 0; bad = 0;
    foreach (codes[k]) begin
      rot(xi, yi, codes[k], ex, ey, xo, yo, of);
      if (fabs(xo - ex) > worst) worst = fabs(xo - ex);
      if (fabs(yo - ey) > worst) worst = fabs(yo - ey);
      if (fabs(xo - ex) > 2.0 || fabs(yo - ey) > 2.0 || of) bad++;
    end
  endtask

  initial begin
    int codes [$]; real worst, w2, ex, ey, sum; int bad, b2, xo, yo, zo, lat, n; bit of, ok;
    real key_deg [10] = '{0.0, 30.0, -30.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0, 180.0};
    int  edges [4];
    reset_dut();
    edges = '{deg2z(90.0), deg2z(-90.0), -32768, 32767};

    // E1: key angles, two inputs
    codes = {};
    foreach (key_deg[k]) codes.push_back(deg2z(key_deg[k]));
    sweep(q(1.0, QXY), 0, codes, worst, bad);
    sweep(q(0.75, QXY), q(-0.4, QXY), codes, w2, b2);
    result("E1", "key angles, (1, 0) and (0.75, -0.4)", bad + b2 == 0,
           $sformatf("worst %0.2f LSB", worst > w2 ? worst : w2));

    // E2: every degree past +-90
    codes = {};
    for (int d = 91; d <= 179; d++) begin codes.push_back(deg2z(d)); codes.push_back(deg2z(-d)); end
    sweep(q(0.6, QXY), q(0.3, QXY), codes, worst, bad);
    result("E2", "91 to 179 and -91 to -179 deg, every degree", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // E3: +-1 LSB around the fold edges
    codes = {};
    foreach (edges[k])
      for (int d = -1; d <= 1; d++) begin
        int c; c = (edges[k] + d) & 16'hFFFF;
        codes.push_back(c >= 32768 ? c - 65536 : c);
      end
    sweep(q(0.8, QXY), q(0.1, QXY), codes, worst, bad);
    result("E3", "+-1 LSB around +-90 and 180 deg: no jump", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // E4: -32768 is both +180 and -180
    rot(q(0.6, QXY), q(-0.2, QXY), -32768, ex, ey, xo, yo, of);
    result("E4", "z = -32768 (180 deg) gives (-x, -y)", fabs(xo - ex) <= 2 && fabs(yo - ey) <= 2,
           $sformatf("(%0d, %0d)", xo, yo));

    // E5: the smallest angles
    codes = '{1, -1};
    sweep(q(0.9, QXY), q(0.3, QXY), codes, worst, bad);
    result("E5", "z = +-1 LSB: output nearly equals input", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // E7: the zero vector stays zero at any angle
    ok = 1;
    for (int k = 0; k < 16; k++) begin
      op(0, 0, 0, 0, deg2z(-180.0 + 22.5 * k), xo, yo, zo, of, lat);
      if (xo != 0 || yo != 0 || of) ok = 0;
    end
    result("E7", "(0, 0) at 16 angles stays (0, 0) exactly", ok, "");

    // E8: tiny vectors, every angle
    worst = 0; sum = 0; n = 0; bad = 0;
    void'($urandom(8));
    for (int k = 0; k < 4000; k++) begin
      int xi, yi;
      do begin xi = int'($urandom_range(9)) - 4; yi = int'($urandom_range(9)) - 4; end
      while ((xi == 0 && yi == 0) || xi * xi + yi * yi > 16);
      rot(xi, yi, int'($urandom() & 16'hFFFF) - 32768, ex, ey, xo, yo, of);
      if (fabs(xo - ex) > worst) worst = fabs(xo - ex);
      if (fabs(yo - ey) > worst) worst = fabs(yo - ey);
      if (fabs(xo - ex) > 2.0 || fabs(yo - ey) > 2.0) bad++;
      sum += (xo - ex) + (yo - ey); n += 2;
    end
    result("E8", "4,000 vectors of length 1 to 4 LSB", bad == 0 && fabs(sum / n) <= 0.1,
           $sformatf("worst %0.2f LSB, mean %0.4f LSB", worst, sum / n));

    // E9: unit vector at 4,096 angles
    codes = {};
    for (int c = -32768; c < 32768; c += 16) codes.push_back(c);
    sweep(q(1.0, QXY), 0, codes, worst, bad);
    result("E9", "(1, 0) at 4,096 angles, no saturation", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // E10: the largest input; out-of-range parts saturate with ovf, the rest within 2 LSB
    bad = 0;
    for (int k = 0; k < 720; k++) begin
      bit sx, sy; int wx, wy;
      rot(q(1.99, QXY), q(1.99, QXY), deg2z(-180.0 + 0.5 * k), ex, ey, xo, yo, of);
      sx = ex > WMAX + 0.5 || ex < WMIN - 0.5;
      sy = ey > WMAX + 0.5 || ey < WMIN - 0.5;
      wx = ex > WMAX ? WMAX : ex < WMIN ? WMIN : 0;
      wy = ey > WMAX ? WMAX : ey < WMIN ? WMIN : 0;
      if (sx ? xo != wx : fabs(xo - ex) > 2.0) bad++;
      else if (sy ? yo != wy : fabs(yo - ey) > 2.0) bad++;
      else if ((sx || sy) && !of) bad++;
      else if (!(sx || sy) && of && fabs(fabs(ex) - WMAX) > 2.0 && fabs(fabs(ey) - WMAX) > 2.0) bad++;
    end
    result("E10", "(1.99, 1.99) at 720 angles: saturate, ovf, no wrap", bad == 0, $sformatf("%0d bad", bad));

    // E11: there and back
    bad = 0; worst = 0;
    void'($urandom(11));
    for (int k = 0; k < 500; k++) begin
      int xi, yi, zi, x1, y1, x2, y2;
      xi = q(-0.7 + 1.4 * ($urandom() / 4294967296.0), QXY);
      yi = q(-0.7 + 1.4 * ($urandom() / 4294967296.0), QXY);
      zi = int'($urandom() & 16'hFFFF) - 32768;
      if (zi == -32768) zi = 1;
      op(0, 0, xi, yi, zi, x1, y1, zo, of, lat);
      op(0, 0, x1, y1, -zi, x2, y2, zo, of, lat);
      if (fabs(x2 - xi) > worst) worst = fabs(x2 - xi);
      if (fabs(y2 - yi) > worst) worst = fabs(y2 - yi);
      if (fabs(x2 - xi) > 4 || fabs(y2 - yi) > 4) bad++;
    end
    result("E11", "500 round trips, back within 4 LSB", bad == 0, $sformatf("worst %0.0f LSB", worst));

    wait (d8);
    $display("DONE: %0d passed, %0d failed", n_pass + p8, n_fail + f8);
    $finish;
  end
endmodule
