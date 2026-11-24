`timescale 1ns/1ps
// tb_linear_pipe.sv : test group G, linear mode: multiply and divide (W = 16, N = 16)
// Multiply is linear rotation: y = y0 + x * z. Divide is linear vectoring: z = y / x.
//   G1  Multiply with z = +-0.5 and +-0.99          -> within 2 LSB
//   G2  Multiply by zero: z = 0                       -> y unchanged
//   G3  Signs: every sign combination of x and z      -> correct sign
//   G4  Multiply out of range: y0 = 1, x = 1.9, z = 0.9 -> saturates, ovf = 1
//   G5  Divide z = y / x with |y| < |x|, both signs   -> within 2 LSB
//   G6  Divide out of range: |y| > |x|                -> ovf = 1
//   G7  Divide by zero: x = 0                         -> ovf = 1, finishes normally

module tb_linear_pipe;
  localparam int W = 16, N = 16;
  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_pipe #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;
  `include "tb_common.svh"

  // multiply: returns the error of y in LSBs and ovf
  task automatic mul(input real xr, input real y0r, input real zr, output real err, output int yo, output bit of);
    int xi, yi, zi, xo, zo, lat; real x0, y0, z0;
    xi = q(xr, QXY); yi = q(y0r, QXY); zi = q(zr, QZL);
    x0 = xi / QXY; y0 = yi / QXY; z0 = zi / QZL;
    op(1, 0, xi, yi, zi, xo, yo, zo, of, lat);
    err = yo - (y0 + x0 * z0) * QXY;
  endtask

  // divide: returns the error of z in LSBs, ovf and the latency
  task automatic dvd(input real xr, input real yr, output real err, output bit of, output int lat);
    int xi, yi, xo, yo, zo; real x0, y0;
    xi = q(xr, QXY); yi = q(yr, QXY); x0 = xi / QXY; y0 = yi / QXY;
    op(1, 1, xi, yi, 0, xo, yo, zo, of, lat);
    err = (x0 == 0.0) ? 0.0 : zo - (y0 / x0) * QZL;
  endtask

  initial begin
    real e, worst; int yo, bad, lat; bit of, ok;
    real zs [4] = '{0.5, -0.5, 0.99, -0.99};
    real xs [4] = '{0.3, -0.7, 1.2, -1.5};
    real ys [3] = '{0.0, 0.25, -0.4};
    real sx [2] = '{0.6, -0.6};
    real sz [2] = '{0.7, -0.7};
    real gx [3] = '{0.5, -0.5, 0.3};
    real gy [3] = '{0.8, 0.9, -0.9};
    reset_dut();

    // G1
    worst = 0; bad = 0;
    foreach (zs[a]) foreach (xs[b]) foreach (ys[c]) begin
      mul(xs[b], ys[c], zs[a], e, yo, of);
      if (fabs(e) > worst) worst = fabs(e);
      if (fabs(e) > 2.0 || of) bad++;
    end
    result("G1", "48 multiplies, z = +-0.5 and +-0.99", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // G2
    ok = 1; worst = 0;
    foreach (xs[b]) foreach (ys[c]) begin
      mul(xs[b], ys[c], 0.0, e, yo, of);
      if (fabs(e) > worst) worst = fabs(e);
      if (fabs(e) > 1.0 || of) ok = 0;
    end
    result("G2", "z = 0: y unchanged (within 1 LSB)", ok, $sformatf("worst %0.2f LSB", worst));

    // G3
    ok = 1;
    foreach (sx[a]) foreach (sz[b]) begin
      mul(sx[a], 0.0, sz[b], e, yo, of);
      if ((yo < 0) != (sx[a] * sz[b] < 0) || fabs(e) > 2.0) ok = 0;
    end
    result("G3", "every sign combination of x and z", ok, "");

    // G4
    mul(1.9, 1.0, 0.9, e, yo, of);
    result("G4", "1 + 1.9 * 0.9 = 2.71: saturates with ovf", yo == WMAX && of, $sformatf("y = %0d, ovf %0d", yo, of));

    // G5
    worst = 0; bad = 0;
    void'($urandom(5));
    for (int k = 0; k < 2000; k++) begin
      real xv, yv;
      xv = 0.3 + 1.6 * ($urandom() / 4294967296.0);
      if ($urandom() & 1) xv = -xv;
      yv = (-0.95 + 1.9 * ($urandom() / 4294967296.0)) * fabs(xv);
      dvd(xv, yv, e, of, lat);
      if (fabs(e) > worst) worst = fabs(e);
      if (fabs(e) > 2.0 || of) bad++;
    end
    result("G5", "2,000 divides, |y| < |x|, both signs of x", bad == 0, $sformatf("worst %0.2f LSB", worst));

    // G6
    ok = 1;
    foreach (gx[a]) begin
      dvd(gx[a], gy[a], e, of, lat);
      if (!of) ok = 0;
    end
    result("G6", "|y| > |x| (3 cases): ovf = 1", ok, "");

    // G7
    dvd(0.0, 0.5, e, of, lat);
    ok = of && lat > 0;
    dvd(0.0, 0.0, e, of, lat);
    ok = ok && of && lat > 0;
    result("G7", "x = 0: ovf = 1 and out_valid comes", ok, $sformatf("latency %0d", lat));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
