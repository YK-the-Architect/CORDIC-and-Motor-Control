`timescale 1ns/1ps
// tb_examples.sv : test group X, the worked examples of the report, run on the iterative engine
// (cordic_ss, W = 16, N = 16). Prints:
//   1. a clock-by-clock trace of one rotation, (0.5, 0) by 30 deg: state, i, sigma and the three lanes
//      (x and y before x K, z = the angle still to turn)
//   2. one example of each operation, with the expected value from real math and the error in LSBs
//      (outputs as reals, with the integer output code in brackets)
// Each example must be within 2 LSB of real math (PASS or FAIL per line, DONE at the end).

module tb_examples;
  localparam int W = 16, N = 16, G = 5, IW = W + 2 + G;
  logic clk = 0, rst = 1, start = 0, mode_cl = 0, mode_rv = 0, out_valid, ready, ovf;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0, x_corr, y_corr, z;
  always #5 clk = ~clk;
  cordic_ss #(.WIDTH(W), .ITER(N)) dut (.*);

  `include "tb_common.svh"

  // internal signals for the trace
  wire [1:0]  st  = dut.u_control.state;
  wire [3:0]  it  = dut.u_control.i;
  wire        sg  = dut.u_control.sigma;
  wire signed [IW-1:0] lx = dut.x, ly = dut.y, lz = dut.z_lane;

  function automatic string sname(logic [1:0] s);
    case (s) 0: return "IDLE"; 1: return "EXE "; 2: return "DONE"; default: return "HOLD"; endcase
  endfunction

  // one example: run it, print inputs, outputs, expected values and the error
  task automatic example(input string name, input bit cl, input bit rv, input real xr, input real yr,
                         input real zr, input string zunit);
    int xi, yi, zi, xo, yo, zo, lat;
    bit of, ok;
    real ex, ey, ez, ax, ay, az, err;
    string got, want;
    xi = q(xr, QXY); yi = q(yr, QXY);
    zi = (zunit == "deg") ? deg2z(zr) : q(zr, QZL);
    op(cl, rv, xi, yi, zi, xo, yo, zo, of, lat);
    ax = xo / QXY; ay = yo / QXY;
    if (!cl && !rv) begin                                // rotation
      ex = xr * $cos(zr * PI / 180.0) - yr * $sin(zr * PI / 180.0);
      ey = xr * $sin(zr * PI / 180.0) + yr * $cos(zr * PI / 180.0);
      err = fabs(ax - ex) * QXY; if (fabs(ay - ey) * QXY > err) err = fabs(ay - ey) * QXY;
      got  = $sformatf("x = %.4f (%0d), y = %.4f (%0d)", ax, xo, ay, yo);
      want = $sformatf("x = %.4f, y = %.4f", ex, ey);
    end else if (!cl && rv) begin                        // vectoring
      ex = $sqrt(xr * xr + yr * yr);
      ez = zr + $atan2(yr, xr) * 180.0 / PI;
      az = zo * 360.0 / TURN;
      err = fabs(ax - ex) * QXY; if (fabs(az - ez) / 360.0 * TURN > err) err = fabs(az - ez) / 360.0 * TURN;
      got  = $sformatf("x = %.4f (%0d), z = %.3f deg (%0d)", ax, xo, az, zo);
      want = $sformatf("x = %.4f, z = %.3f deg", ex, ez);
    end else if (cl && !rv) begin                        // multiply
      ey = yr + xr * zr;
      err = fabs(ay - ey) * QXY;
      got  = $sformatf("y = %.4f (%0d)", ay, yo);
      want = $sformatf("y = %.4f", ey);
    end else begin                                       // divide
      ez = zr + yr / xr;
      az = zo / QZL;
      err = fabs(az - ez) * QZL;
      got  = $sformatf("z = %.4f (%0d)", az, zo);
      want = $sformatf("z = %.4f", ez);
    end
    ok = err <= 2.0 && !of;
    result("X", name, ok, $sformatf("got %s | real math %s | error %.2f LSB | %0d clocks | ovf %0d",
                                    got, want, err, lat, of));
  endtask

  initial begin
    int cyc;
    repeat (2) @(negedge clk);
    rst = 0;

    // 1. trace of one rotation
    $display("Trace: rotate (0.5, 0) by 30 deg. Lanes as reals: x, y before x K (1.0 = 2^19), z in degrees.");
    $display("clock  state  i   sigma  x lane     y lane     z lane (deg)");
    @(negedge clk);
    mode_cl = 0; mode_rv = 0; x_in = q(0.5, QXY); y_in = 0; z_in = deg2z(30.0); start = 1;
    cyc = 0;
    do begin
      @(posedge clk); #1;
      start = 0;
      cyc++;
      $display("%5d  %s  %2d  %0d      %8.5f   %8.5f   %9.4f", cyc, sname(st), it, sg,
               real'(lx) / 2.0 ** (W - 2 + G), real'(ly) / 2.0 ** (W - 2 + G), real'(lz) * 360.0 / 2.0 ** (W + G));
    end while (!out_valid && cyc < 40);
    $display("out_valid at clock %0d: x_corr = %.4f, y_corr = %.4f (after x K and rounding)", cyc,
             x_corr / QXY, y_corr / QXY);
    repeat (2) @(negedge clk);

    // 2. one example of each operation
    example("rotate (0.5, 0) by 30 deg",          0, 0, 0.5, 0.0, 30.0, "deg");
    example("rotate (0.5, 0) by 150 deg (fold)",  0, 0, 0.5, 0.0, 150.0, "deg");
    example("vector (0.3, 0.4): length, angle",   0, 1, 0.3, 0.4, 0.0, "deg");
    example("vector (-0.3, -0.4): third quadrant", 0, 1, -0.3, -0.4, 0.0, "deg");
    example("multiply 1.5 x 0.25",                1, 0, 1.5, 0.0, 0.25, "q15");
    example("divide 0.3 / 0.6",                   1, 1, 0.6, 0.3, 0.0, "q15");
    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
