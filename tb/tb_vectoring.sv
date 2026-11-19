`timescale 1ns/1ps
// tb_vectoring.sv : test group F, vectoring in circular mode: magnitude and angle (Sindhura)
//
//   F1  Positive x axis  (0.5, 0)        -> angle 0, magnitude 0.5
//   F2  Negative x axis  (-0.5, 0)       -> angle 180 deg, magnitude 0.5
//   F3  y axis           (0, +-0.5)      -> +-90 deg, magnitude 0.5
//   F4  Diagonals        (+-0.5, +-0.5)  -> +-45 and +-135 deg, magnitude 0.7071
//   F5  Zero vector      (0, 0)          -> magnitude 0, angle 0 (spec choice), finishes normally
//   F6  Long vector      (1, 1)          -> magnitude 1.4142 (2.33 inside before x K: needs the headroom)
//   F7  Every quadrant   4,000 random vectors in all four quadrants -> within 2 LSB
//
// W = 16, N = 16. Magnitude error is in LSBs of x (Q2.14), angle error in LSBs of z
// (2^16 = 360 deg). Expected values come from real math on the quantized inputs.

module tb_vectoring;
  localparam int  W = 16, N = 16;
  localparam real PI   = 3.14159265358979323846;
  localparam real QXY  = real'(1 << (W - 2));
  localparam real TURN = real'(1 << W);
  localparam real TOL  = 2.0;

  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);
  always #5 clk = ~clk;

  int n_pass = 0, n_fail = 0;

  function automatic int q(real v);
    real s; int c;
    s = v * QXY; c = $rtoi(s + (s >= 0 ? 0.5 : -0.5));
    if (c >  (1 << (W - 1)) - 1) c =  (1 << (W - 1)) - 1;
    if (c < -(1 << (W - 1)))     c = -(1 << (W - 1));
    return c;
  endfunction
  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction

  // one vectoring operation; returns the magnitude and angle errors in LSBs
  task automatic vec(input real xr, input real yr, output bit fin, output real emag, output real eang);
    int xi, yi, t; real x0, y0, mag, ang, d;
    xi = q(xr); yi = q(yr); x0 = xi / QXY; y0 = yi / QXY;
    @(negedge clk);
    mode_cl = 0; mode_rv = 1; x_in = xi; y_in = yi; z_in = 0; start = 1;
    @(negedge clk);
    start = 0; t = 0;
    while (!out_valid && t < 4 * N + 10) begin @(negedge clk); t++; end
    fin  = out_valid;
    mag  = $sqrt(x0 * x0 + y0 * y0);
    ang  = (xi == 0 && yi == 0) ? 0.0 : $atan2(y0, x0) / (2.0 * PI) * TURN;
    emag = x_corr - mag * QXY;
    d = z - ang;
    while (d >=  TURN / 2) d -= TURN;
    while (d <  -TURN / 2) d += TURN;
    eang = d;
    @(negedge clk);
  endtask

  function automatic string cause(real xr, real yr);
    if (xr < 0)              return "  <- needs RTL change 2 (vectoring pre-rotation for x < 0)";
    if (xr == 0 && yr == 0)  return "  <- zero vector: the angle comes out as the sum of the atan table";
    return "";
  endfunction

  task automatic check(input string id, input string what, input real xr, input real yr);
    bit fin, ok; real em, ea;
    vec(xr, yr, fin, em, ea);
    ok = fin && fabs(em) <= TOL && fabs(ea) <= TOL;
    $display("%s %s  %-30s (%5.2f, %5.2f)  mag err %7.2f LSB  angle err %9.2f LSB%s",
             ok ? "PASS" : "FAIL", id, what, xr, yr, em, ea, ok ? "" : cause(xr, yr));
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int qpass [4], qtot [4], qd;
    bit fin; real em, ea, xr, yr;
    string qname [4] = '{"I (x>0, y>0)", "II (x<0, y>0)", "III (x<0, y<0)", "IV (x>0, y<0)"};
    rst = 1; start = 0; mode_cl = 0; mode_rv = 1; x_in = 0; y_in = 0; z_in = 0;
    repeat (3) @(negedge clk);
    rst = 0;

    check("F1", "positive x axis",              0.5,  0.0);
    check("F2", "negative x axis",             -0.5,  0.0);
    check("F3", "y axis, +90 deg",              0.0,  0.5);
    check("F3", "y axis, -90 deg",              0.0, -0.5);
    check("F4", "diagonal, +45 deg",            0.5,  0.5);
    check("F4", "diagonal, -45 deg",            0.5, -0.5);
    check("F4", "diagonal, +135 deg",          -0.5,  0.5);
    check("F4", "diagonal, -135 deg",          -0.5, -0.5);
    check("F5", "zero vector",                  0.0,  0.0);
    check("F6", "long vector (needs headroom)", 1.0,  1.0);

    // F7: random vectors in every quadrant, |v| >= 0.25 so the angle is defined to an LSB
    void'($urandom(77));
    qpass = '{0, 0, 0, 0}; qtot = '{0, 0, 0, 0};
    for (int k = 0; k < 4000; k++) begin
      do begin
        xr = -0.7 + 1.4 * ($urandom() / 4294967296.0);
        yr = -0.7 + 1.4 * ($urandom() / 4294967296.0);
      end while ($sqrt(xr * xr + yr * yr) < 0.25 || q(xr) == 0 || q(yr) == 0);
      qd = (xr > 0) ? ((yr > 0) ? 0 : 3) : ((yr > 0) ? 1 : 2);
      vec(xr, yr, fin, em, ea);
      qtot[qd]++;
      if (fin && fabs(em) <= TOL && fabs(ea) <= TOL) qpass[qd]++;
    end
    for (int k = 0; k < 4; k++) begin
      $display("%s F7  random, quadrant %-16s %4d of %4d within 2 LSB%s",
               qpass[k] == qtot[k] ? "PASS" : "FAIL", qname[k], qpass[k], qtot[k],
               (qpass[k] != qtot[k] && (k == 1 || k == 2)) ? "  <- needs RTL change 2 (x < 0)" : "");
      if (qpass[k] == qtot[k]) n_pass++; else n_fail++;
    end

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
