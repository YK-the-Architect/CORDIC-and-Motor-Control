`timescale 1ns/1ps
// tb_output.sv : test group C, output stage: x K, banker's rounding, saturation
// The output stage alone, W = 16 with G = 5 guard bits (the engine's default for N = 16).
//   C1  Gain compensation: internal 1.6468 (a unit vector after 16 iterations) -> 1.0 within 1 LSB
//   C2  Ties go to even: dropped bits exactly half, 2.5 and 3.5 LSB          -> 2 and 4
//   C3  Negative ties: -2.5 and -3.5 LSB                                     -> -2 and -4
//   C4  Just off the tie: half minus or plus one guard LSB                   -> rounds down, rounds up
//   C5  Saturate high: result of +2.0 or more                                -> +32767, sat = 1
//   C6  Saturate low: result below -2.0                                      -> -32768, sat = 1
//   C7  No false saturation: results of exactly +1.99994 and -2.0            -> unchanged, sat = 0
//   C8  z in circular mode is an angle: 200 deg wraps to -160 deg            -> no sat

module tb_output;
  localparam int W = 16, G = 5, IW = W + 2 + G;
  localparam real ONE_LANE = real'(1 << (W - 2 + G));   // 1.0 in the lane (x, y)

  logic scale_en, out_valid, sat;
  logic signed [IW-1:0] x, y, z;
  logic signed [W-1:0]  x_corr, y_corr, z_corr;
  error_correction #(.WIDTH(W), .G(G)) dut (.*);

  int n_pass = 0, n_fail = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-3s %-46s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  // value in output LSBs, placed in the lane with its guard bits; linear path (no x K)
  function automatic logic signed [IW-1:0] lsb(real v);
    return IW'($rtoi(v * real'(1 << G)));
  endfunction

  task automatic round_case(input string id, input real in_lsb, input int want);
    scale_en = 0; out_valid = 1; x = lsb(in_lsb); y = -lsb(in_lsb); z = 0; #1;
    chk(id, $sformatf("%0.5f LSB rounds to %0d (and -%0.5f to %0d)", in_lsb, want, in_lsb, -want),
        x_corr == want && y_corr == -want && !sat,
        $sformatf("got %0d and %0d", x_corr, y_corr));
  endtask

  initial begin
    real a16, g;
    // C1: gain after 16 iterations, times K, back to 1.0
    a16 = 1.0;
    for (int i = 0; i < 16; i++) a16 *= $sqrt(1.0 + 2.0 ** (-2 * i));
    scale_en = 1; out_valid = 1; x = IW'($rtoi(a16 * ONE_LANE)); y = 0; z = 0; #1;
    chk("C1", $sformatf("internal %0.4f x K -> 1.0 (16384)", a16),
        x_corr >= 16383 && x_corr <= 16385 && !sat, $sformatf("got %0d", x_corr));

    // C2 to C4: rounding of the guard bits (linear path, no x K)
    g = 1.0 / real'(1 << G);                 // one guard LSB, in output LSBs
    round_case("C2", 2.5, 2);
    round_case("C2", 3.5, 4);
    scale_en = 0; out_valid = 1; x = lsb(-2.5); y = lsb(-3.5); z = 0; #1;
    chk("C3", "-2.5 and -3.5 LSB round to -2 and -4", x_corr == -2 && y_corr == -4 && !sat,
        $sformatf("got %0d and %0d", x_corr, y_corr));
    round_case("C4", 2.5 - g, 2);
    round_case("C4", 2.5 + g, 3);
    round_case("C4", 3.5 - g, 3);

    // C5, C6: saturation, both paths
    scale_en = 0; out_valid = 1; x = lsb(32768.0); y = lsb(40000.0); z = 0; #1;
    chk("C5", "+2.0 and +2.44 (linear) -> +32767", x_corr == 32767 && y_corr == 32767 && sat,
        $sformatf("got %0d, %0d, sat %0d", x_corr, y_corr, sat));
    scale_en = 1; x = IW'($rtoi(3.5 * ONE_LANE)); y = IW'($rtoi(-3.4 * ONE_LANE)); #1;
    chk("C5", "internal 3.5 x K = 2.13 (circular) -> +32767", x_corr == 32767 && sat,
        $sformatf("got %0d, sat %0d", x_corr, sat));
    chk("C6", "internal -3.4 x K = -2.06 (circular) -> -32768", y_corr == -32768 && sat,
        $sformatf("got %0d, sat %0d", y_corr, sat));
    scale_en = 0; x = lsb(-32769.0); y = lsb(-50000.0); #1;
    chk("C6", "-2.00006 and -3.05 (linear) -> -32768", x_corr == -32768 && y_corr == -32768 && sat,
        $sformatf("got %0d, %0d, sat %0d", x_corr, y_corr, sat));

    // C7: the exact limits pass through
    scale_en = 0; x = lsb(32767.0); y = lsb(-32768.0); z = 0; #1;
    chk("C7", "+1.99994 and -2.0 exactly: unchanged", x_corr == 32767 && y_corr == -32768 && !sat,
        $sformatf("got %0d, %0d, sat %0d", x_corr, y_corr, sat));

    // C8: z wraps in circular mode (an angle), saturates in linear mode (a number)
    scale_en = 1; x = 0; y = 0; z = IW'($rtoi(200.0 / 360.0 * real'(1 << (W + G)))); #1;
    chk("C8", "z = 200 deg, circular: wraps to -160 deg", !sat && z_corr == -29127,
        $sformatf("got %0d (%0.2f deg)", z_corr, z_corr * 360.0 / 65536.0));
    scale_en = 0; z = lsb(40000.0); #1;
    chk("C8", "z = +1.22, linear: saturates to +0.99997", sat && z_corr == 32767,
        $sformatf("got %0d, sat %0d", z_corr, sat));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
