`timescale 1ns/1ps
// tb_datapath.sv : test group U7, the iterative engine's datapath on its own (rtl/datapath.sv).
// The testbench plays the control unit: it pulses init, then steps i, m and sigma the way control.sv does
// (circular i = 0 to 15, linear i = 1 to 15; sigma = ~z_msb in rotation, y_msb in vectoring). After every
// clock it checks the three lanes against its own model of one CORDIC iteration (W = 16, G = 5, 23-bit lanes):
//   sigma = 1:  x' = x - m (y >>> i)   y' = y + (x >>> i)   z' = z - (m ? atan(2^-i) : 2^-i)
//   sigma = 0:  x' = x + m (y >>> i)   y' = y - (x >>> i)   z' = z + (m ? atan(2^-i) : 2^-i)
// with atan(2^-i) from real math in the testbench, not from atan_rom.
//   U7.1  init loads the lanes: inputs sign-extended and moved up by the G = 5 guard bits (cases with no fold)
//   U7.2  Fold: rotation with z in quadrant II or III, and vectoring with x < 0, negate x and y and move z by
//         180 deg; linear mode never folds z; divide with x < 0 negates x and y only; x = -2.0 folds to +2.0
//   U7.3  Every iteration matches the model bit for bit: 2,000 random operations in each of the 4 modes,
//         all three lanes after every clock and lane_ovf on every clock
//   U7.4  The lanes after the last iteration agree with real math within 4 output LSBs (circular results
//         still carry the CORDIC gain 1.6468 here; the output stage removes it)
//   U7.5  Zero vector in circular vectoring: z holds at z_in through every iteration, x and y stay 0
//   U7.6  lane_ovf stays 0 in every legal operation above; a schedule the control never produces (linear,
//         i = 0 over and over) pushes y past the lane range, and lane_ovf rises on the clock the model overflows

module tb_datapath;
  localparam int W = 16, N = 16, G = 5, IW = W + 2 + G, SW = $clog2(N);
  localparam real PI = 3.14159265358979323846;

  logic clk = 0, rst = 1;
  logic init = 0, en = 0, sigma = 0, m = 0, mode_cl = 0, mode_rv = 0;
  logic [SW-1:0] i = '0;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0;
  logic signed [IW-1:0] x, y, z;
  logic lane_ovf;
  always #5 clk = ~clk;

  datapath #(.WIDTH(W), .ITER(N), .G(G)) dut (.*);

  // ---- model ----
  logic signed [IW-1:0] mx, my, mz;
  logic signed [IW-1:0] at [N];
  bit mzhold;

  function automatic void model_init(bit cl, bit rv, int xi, int yi, int zi, output bit folded);
    logic signed [W-1:0] xs, ys, zs;
    logic signed [IW-1:0] xe, ye;
    bit fold, neg;
    xs = W'(xi); ys = W'(yi); zs = W'(zi);
    fold = !cl && (rv ? xs[W-1] : (zs[W-1] ^ zs[W-2]));
    neg  = fold || (cl && rv && xs[W-1]);
    xe = IW'(xs) <<< G;
    ye = IW'(ys) <<< G;
    mx = neg ? -xe : xe;
    my = neg ? -ye : ye;
    if (fold) zs[W-1] = ~zs[W-1];
    mz = IW'(zs) <<< G;
    mzhold = !cl && rv && (xs == 0) && (ys == 0);
    folded = neg;
  endfunction

  // one iteration; returns the overflow flag of the three add/subs, as add_sub.sv computes it
  function automatic bit model_step(int k, bit mm, bit sg);
    logic signed [IW:0] rx, ry, rz;
    logic signed [IW-1:0] xs, ys, bx, ang;
    xs  = mx >>> k;
    ys  = my >>> k;
    bx  = mm ? ys : '0;
    ang = mm ? at[k] : (IW'(1) <<< (W - 1 + G - k));
    rx = sg  ? (IW+1)'(mx) - (IW+1)'(bx)  : (IW+1)'(mx) + (IW+1)'(bx);
    ry = !sg ? (IW+1)'(my) - (IW+1)'(xs)  : (IW+1)'(my) + (IW+1)'(xs);
    rz = sg  ? (IW+1)'(mz) - (IW+1)'(ang) : (IW+1)'(mz) + (IW+1)'(ang);
    mx = rx[IW-1:0];
    my = ry[IW-1:0];
    if (!mzhold) mz = rz[IW-1:0];
    return (rx[IW] != rx[IW-1]) || (ry[IW] != ry[IW-1]) || (rz[IW] != rz[IW-1]);
  endfunction

  function automatic bit lanes_ok();
    return x === mx && y === my && z === mz;
  endfunction

  // ---- driving the datapath like control.sv ----
  int n_pass = 0, n_fail = 0, ovf_clocks = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-60s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  task automatic do_init(input bit cl, input bit rv, input int xi, input int yi, input int zi,
                         output bit bad, output bit folded);
    @(negedge clk);
    mode_cl = cl; mode_rv = rv; x_in = W'(xi); y_in = W'(yi); z_in = W'(zi);
    init = 1; en = 1; m = 0; sigma = 0;
    model_init(cl, rv, xi, yi, zi, folded);
    @(negedge clk);
    init = 0; en = 0;
    bad = !lanes_ok();
  endtask

  // one EXE clock with a given i, m and sigma; flag = lane_ovf seen before the edge, mflag = the model's
  task automatic do_step(input int k, input bit mm, input bit sg, output bit bad, output bit flag,
                         output bit mflag);
    i = SW'(k); m = mm; sigma = sg; en = 1;
    #1;
    flag = lane_ovf;
    mflag = model_step(k, mm, sg);
    @(negedge clk);
    en = 0;
    bad = (flag !== mflag) || !lanes_ok();
  endtask

  // a whole operation; returns how many clocks disagreed with the model
  task automatic run(input bit cl, input bit rv, input int xi, input int yi, input int zi,
                     output bit init_bad, output int step_bad, output bit folded);
    bit b, f, mf;
    do_init(cl, rv, xi, yi, zi, init_bad, folded);
    step_bad = 0;
    for (int k = cl ? 1 : 0; k < N; k++) begin
      do_step(k, !cl, rv ? y[IW-1] : ~z[IW-1], b, f, mf);
      if (b) step_bad++;
      if (f) ovf_clocks++;
    end
  endtask

  // ---- real math for U7.4 ----
  real gain, max_err [4];
  int  n_end_bad [4], n_angle_checked;

  function automatic real lsb(logic signed [IW-1:0] v); return real'(v) / real'(1 << G); endfunction
  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction
  function automatic real wrap(real d, real turn);
    while (d >=  turn / 2) d -= turn;
    while (d <  -turn / 2) d += turn;
    return d;
  endfunction

  // the error of the final lanes, in output LSBs (worst lane); -1 if the case is not checked
  function automatic real end_error(bit cl, bit rv, int xi, int yi, int zi);
    real th, e, r, ex, ey, ez;
    if (!cl && !rv) begin                                  // rotation: gain * (x, y) turned by z
      th = real'(zi) * 2.0 * PI / 65536.0;
      ex = gain * (xi * $cos(th) - yi * $sin(th));
      ey = gain * (xi * $sin(th) + yi * $cos(th));
      e  = fabs(lsb(x) - ex);
      if (fabs(lsb(y) - ey) > e) e = fabs(lsb(y) - ey);
    end else if (!cl && rv) begin                          // vectoring: (gain |v|, 0), z_in + angle
      r = $sqrt(real'(xi) * xi + real'(yi) * yi);
      e = fabs(lsb(x) - gain * r);
      if (fabs(lsb(y)) > e) e = fabs(lsb(y));
      if (r >= 4096.0) begin                               // the angle is only sharp for |v| >= 0.25
        ez = wrap(lsb(z) - (zi + $atan2(real'(yi), real'(xi)) * 65536.0 / (2.0 * PI)), 65536.0);
        if (fabs(ez) > e) e = fabs(ez);
        n_angle_checked++;
      end
    end else if (cl && !rv) begin                          // multiply: y + x z, x unchanged
      ey = yi + real'(xi) * real'(zi) / 32768.0;
      e = fabs(lsb(y) - ey);
      if (fabs(lsb(x) - xi) > e) e = fabs(lsb(x) - xi);
    end else begin                                         // divide: z_in + y / x
      if (xi > -4096 && xi < 4096) return -1.0;
      ez = zi + real'(yi) / real'(xi) * 32768.0;
      e = fabs(lsb(z) - ez);
    end
    return e;
  endfunction

  initial begin
    bit ib, fo, b, f;
    int sb, n_init_bad, n_fold_bad, n_init, n_fold, n_step_bad, n_steps, first_ovf, first_model;
    int xi, yi, zi;
    real e;
    bit ok;
    void'($urandom(71));
    gain = 1.0;
    for (int k = 0; k < N; k++) begin
      gain *= $sqrt(1.0 + 2.0 ** (-2 * k));
      at[k] = IW'($rtoi($atan(2.0 ** (-k)) / (2.0 * PI) * (2.0 ** (W + G)) + 0.5));
    end
    for (int md = 0; md < 4; md++) begin max_err[md] = 0.0; n_end_bad[md] = 0; end
    n_angle_checked = 0;
    repeat (2) @(negedge clk);
    rst = 0;

    // U7.2 directed fold cases (also checked step by step and against real math below)
    n_fold = 0; n_fold_bad = 0; n_init = 0; n_init_bad = 0; n_step_bad = 0; n_steps = 0;
    begin
      int cases [8][5] = '{
        '{0, 0,  8192,  4096,  21845},     // rotate by 120 deg: quadrant II, folds
        '{0, 0,  8192, -4096, -21845},     // rotate by -120 deg: quadrant III, folds
        '{0, 0, 16384,     0,  16384},     // exactly 90 deg: folds to -90 deg with (x, y) negated
        '{0, 0, 16384,     0, -32768},     // 180 deg: folds to 0 deg
        '{0, 1, -16384,  8192,     0},     // vectoring, x < 0: folds
        '{0, 1, -32768,     0,     0},     // vectoring, x = -2.0: folds to +2.0, no overflow
        '{1, 0, -16384,  4096,  16384},    // multiply with x < 0: linear never folds
        '{1, 1, -16384,  4096,      0}     // divide with x < 0: x and y negated, z not moved
      };
      for (int c = 0; c < 8; c++) begin
        run(cases[c][0], cases[c][1], cases[c][2], cases[c][3], cases[c][4], ib, sb, fo);
        // a fold is expected in cases 0 to 5 and 7 (negation only); none in case 6
        if (fo != (c != 6) || ib) n_fold_bad++;
        if (sb) n_step_bad++;
        n_steps++;
        e = end_error(cases[c][0], cases[c][1], cases[c][2], cases[c][3], cases[c][4]);
        if (e > 4.0) n_fold_bad++;
      end
    end
    chk("U7.2", "fold and negation: 120, -120, 90, 180 deg, x < 0, x = -2.0", n_fold_bad == 0,
        $sformatf("%0d wrong", n_fold_bad));

    // U7.3 / U7.4 random operations in every mode
    for (int md = 0; md < 4; md++) begin
      bit cl, rv;
      cl = md[1]; rv = md[0];
      for (int k = 0; k < 2000; k++) begin
        xi = $signed(16'($urandom())); yi = $signed(16'($urandom())); zi = $signed(16'($urandom()));
        if (cl && !rv && zi == -32768) zi = -32767;                    // multiply: |z| < 1
        if (cl && rv) begin                                            // divide: |y| < |x|
          while ((yi < 0 ? -yi : yi) >= (xi < 0 ? -xi : xi)) begin
            xi = $signed(16'($urandom())); yi = $signed(16'($urandom()));
          end
          zi = zi / 4;                                                 // z_in within +-0.25
        end
        run(cl, rv, xi, yi, zi, ib, sb, fo);
        if (!fo) begin n_init++; if (ib) n_init_bad++; end
        else     begin n_fold++; if (ib) n_fold_bad++; end
        if (sb) n_step_bad++;
        n_steps++;
        e = end_error(cl, rv, xi, yi, zi);
        if (e > max_err[md]) max_err[md] = e;
        if (e > 4.0) n_end_bad[md]++;
      end
    end
    chk("U7.1", "init loads the lanes (inputs << G, sign-extended)", n_init_bad == 0,
        $sformatf("%0d operations without a fold, %0d wrong", n_init, n_init_bad));
    chk("U7.2", "init with a fold or negation, random inputs", n_fold_bad == 0,
        $sformatf("%0d operations, %0d wrong", n_fold, n_fold_bad));
    chk("U7.3", "every clock bit for bit vs the model, 4 modes x 2,000", n_step_bad == 0,
        $sformatf("%0d operations, %0d with a wrong clock", n_steps, n_step_bad));
    chk("U7.4", "rotation: final lanes vs real math (gain included)", n_end_bad[0] == 0,
        $sformatf("max %.2f LSB", max_err[0]));
    chk("U7.4", "vectoring: gain |v|, y = 0, z_in + angle", n_end_bad[1] == 0,
        $sformatf("max %.2f LSB (%0d angles checked)", max_err[1], n_angle_checked));
    chk("U7.4", "multiply: y + x z", n_end_bad[2] == 0, $sformatf("max %.2f LSB", max_err[2]));
    chk("U7.4", "divide: z_in + y / x (|x| >= 0.25)", n_end_bad[3] == 0, $sformatf("max %.2f LSB", max_err[3]));

    // U7.5 zero vector
    run(0, 1, 0, 0, 1234, ib, sb, fo);
    chk("U7.5", "zero vector: z holds at z_in, x and y stay 0", !ib && sb == 0 && z === (IW'(1234) <<< G) &&
        x === '0 && y === '0, $sformatf("z lane %0d (z_in << 5 = %0d)", z, 1234 << G));

    // U7.6 lane_ovf
    chk("U7.6", "lane_ovf never set in a legal operation", ovf_clocks == 0,
        $sformatf("%0d clocks with lane_ovf = 1", ovf_clocks));
    do_init(1, 0, 32604, 32604, 0, ib, fo);                             // x = y = 1.99, linear rotation
    ok = !ib; first_ovf = -1; first_model = -1;
    for (int k = 1; k <= 6; k++) begin
      bit mf;
      do_step(0, 0, 1, b, f, mf);                                      // i = 0 again: y += x, z -= 1.0
      if (b) ok = 0;
      if (f && first_ovf < 0) first_ovf = k;
      if (mf && first_model < 0) first_model = k;
    end
    chk("U7.6", "forced overflow (linear, i = 0 repeated)",        // y = 9.95 > 8 at step 4
        ok && first_ovf == 4 && first_model == 4,
        $sformatf("lane_ovf first at step %0d, model at step %0d", first_ovf, first_model));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
