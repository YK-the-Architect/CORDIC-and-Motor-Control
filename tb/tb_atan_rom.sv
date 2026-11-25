`timescale 1ns/1ps
// tb_atan_rom.sv : test group U1, the atan(2^-i) table (rtl/atan_rom.sv, written by scripts/gen_atan_rom.py)
// Three tables, checked against real math in the testbench:
//   z lane  WIDTH 23, ANGLE_BITS 21, ITER 16  the table both W = 16 engines use (16 bits + 5 guard bits)
//   16 bit  WIDTH 16, ANGLE_BITS 16, ITER 16  plain 16-bit angles
//   full    WIDTH 40, ANGLE_BITS 40, ITER 32  all 32 entries, close to the 48-bit master constants
//   U1.1  Every entry = round(atan(2^-i) / 360 deg * 2^ANGLE_BITS), within 0.5 LSB (plus the master's own
//         rounding, 2^-(48 - ANGLE_BITS) LSB)
//   U1.2  Entry 0 is exactly 45 deg (2^ANGLE_BITS / 8)
//   U1.3  The entries never increase, and each is at most the sum of all later entries plus the last one,
//         within 1 LSB: the condition for CORDIC to converge, up to the rounding of the table. (In real math
//         the margin is almost 0 at the bottom, where atan(2^-i) is about 2 atan(2^-i-1), so rounding to
//         whole LSBs can cost 1 LSB there.)
//   U1.4  The entries add up to more than 90 deg (99.88 deg for 16 entries), so the engine covers the
//         +-90 deg left after the 180 deg fold

module atan_rom_check #(
  parameter int    WIDTH      = 16,
  parameter int    ITER       = 16,
  parameter int    ANGLE_BITS = WIDTH,
  parameter string NAME       = ""
)(
  output int n_pass,
  output int n_fail,
  output bit done
);
  localparam real PI = 3.14159265358979323846;
  logic [WIDTH-1:0] t [ITER];
  atan_rom #(.WIDTH(WIDTH), .ITER(ITER), .ANGLE_BITS(ANGLE_BITS)) dut (.atan_out(t));

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-8s %-52s %s", ok ? "PASS" : "FAIL", id, NAME, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    real scale, v, err, max_err, tol, sum, later;
    bit ok;
    n_pass = 0; n_fail = 0; done = 0;
    #1;
    scale = (2.0 ** ANGLE_BITS) / (2.0 * PI);          // radians -> table units

    // U1.1 every entry against real math
    max_err = 0.0;
    tol = 0.5 + 2.0 ** (ANGLE_BITS - 48);
    for (int k = 0; k < ITER; k++) begin
      v = $atan(2.0 ** (-k)) * scale;
      err = real'(t[k]) - v;
      if (err < 0) err = -err;
      if (err > max_err) max_err = err;
    end
    chk("U1.1", $sformatf("%0d entries = round(atan(2^-i) * 2^%0d / 360 deg)", ITER, ANGLE_BITS),
        max_err <= tol, $sformatf("max error %.4f LSB", max_err));

    // U1.2 45 degrees exactly
    chk("U1.2", "entry 0 is exactly 45 deg", real'(t[0]) == 2.0 ** (ANGLE_BITS - 3),
        $sformatf("%0d", t[0]));

    // U1.3 never increasing, and the convergence condition on the stored values, within 1 LSB
    ok = 1;
    for (int k = 1; k < ITER; k++) if (t[k] > t[k - 1]) ok = 0;
    max_err = -1.0e30;                                   // worst (entry - later sum - last)
    for (int k = 0; k < ITER; k++) begin
      later = real'(t[ITER - 1]);
      for (int j = k + 1; j < ITER; j++) later += real'(t[j]);
      if (real'(t[k]) - later > max_err) max_err = real'(t[k]) - later;
    end
    if (max_err > 1.0) ok = 0;
    chk("U1.3", "never increasing; each <= later entries + last + 1 LSB", ok,
        $sformatf("worst margin %0.0f LSB", max_err));

    // U1.4 the range CORDIC can reach
    sum = 0.0;
    for (int k = 0; k < ITER; k++) sum += real'(t[k]);
    sum = sum * 360.0 / (2.0 ** ANGLE_BITS);
    chk("U1.4", "entries add up to more than 90 deg", sum > 90.0, $sformatf("%.4f deg", sum));
    done = 1;
  end
endmodule

module tb_atan_rom;
  int p0, f0, p1, f1, p2, f2;
  bit d0, d1, d2;
  atan_rom_check #(.WIDTH(23), .ITER(16), .ANGLE_BITS(21), .NAME("z lane")) c_lane (.n_pass(p0), .n_fail(f0), .done(d0));
  atan_rom_check #(.WIDTH(16), .ITER(16), .ANGLE_BITS(16), .NAME("16 bit")) c_16 (.n_pass(p1), .n_fail(f1), .done(d1));
  atan_rom_check #(.WIDTH(40), .ITER(32), .ANGLE_BITS(40), .NAME("full"))   c_full (.n_pass(p2), .n_fail(f2), .done(d2));

  initial begin
    wait (d0 && d1 && d2);
    $display("DONE: %0d passed, %0d failed", p0 + p1 + p2, f0 + f1 + f2);
    $finish;
  end
endmodule
