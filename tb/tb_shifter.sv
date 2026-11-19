`timescale 1ns/1ps
// tb_shifter.sv : test group A, barrel shifter (Sindhura)
//
//   A1  No shift: i = 0, any input -> output equals input
//   A2  Positive input, every shift: +0.5, i = 0 to N - 1 -> equals >>>
//   A3  Negative input, every shift: -0.6, i = 0 to N - 1 -> sign kept, equals >>>
//   A4  Most negative input: -2.0, every i -> stays negative, ends at -1
//   A5  -1 at every shift -> stays -1
//   A6  Exhaustive: W = 8, all 256 inputs, all shifts -> equals >>>
//   A7  Shift amounts above 15: N = 20, i = 16 to 19 -> correct, no wraparound (the SHIFT_W bug)
//   A8  Engine lane width: 23 bits (W = 16 + 2 headroom + 5 guard), random inputs, all shifts
//
// x and y are Q2.(W-2), so at W = 16: +0.5 = 8192, -0.6 = -9830, -2.0 = -32768.

module tb_shifter;
  int n_pass = 0, n_fail = 0;

  // W = 16, N = 16
  logic signed [15:0] d16, o16;  logic [3:0] s16;
  shifter #(.WIDTH(16), .SHIFT_W(4)) u16 (.data_in(d16), .shift_amt(s16), .data_out(o16));
  // W = 8, N = 8
  logic signed [7:0]  d8,  o8;   logic [2:0] s8;
  shifter #(.WIDTH(8),  .SHIFT_W(3)) u8  (.data_in(d8),  .shift_amt(s8),  .data_out(o8));
  // W = 20, N = 20
  logic signed [19:0] d20, o20;  logic [4:0] s20;
  shifter #(.WIDTH(20), .SHIFT_W(5)) u20 (.data_in(d20), .shift_amt(s20), .data_out(o20));
  // lane width inside the engine at W = 16, N = 16
  logic signed [22:0] d23, o23;  logic [3:0] s23;
  shifter #(.WIDTH(23), .SHIFT_W(4)) u23 (.data_in(d23), .shift_amt(s23), .data_out(o23));

  // each shift checks out == in >>> i; returns 1 on a match
  function automatic bit ok16(int got, logic signed [15:0] d, int s); return got == int'(d >>> s); endfunction

  task automatic result(input string id, input string what, input int bad);
    $display("%s %s  %s%s", bad == 0 ? "PASS" : "FAIL", id, what,
             bad == 0 ? "" : $sformatf("  (%0d mismatches)", bad));
    if (bad == 0) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad;
    logic signed [15:0] vals [7] = '{16'sd0, 16'sd1, -16'sd1, 16'sd8192, -16'sd9830, 16'sd32767, -16'sd32768};

    // A1: i = 0 passes the input through
    bad = 0;
    foreach (vals[k]) begin d16 = vals[k]; s16 = 0; #1; if (o16 !== vals[k]) bad++; end
    result("A1", "no shift (i = 0), 7 inputs", bad);

    // A2: +0.5 at every shift
    bad = 0;
    for (int s = 0; s < 16; s++) begin d16 = 16'sd8192; s16 = s; #1; if (!ok16(o16, d16, s)) bad++; end
    result("A2", "+0.5 at i = 0 to 15", bad);

    // A3: -0.6 at every shift, sign kept
    bad = 0;
    for (int s = 0; s < 16; s++) begin
      d16 = -16'sd9830; s16 = s; #1;
      if (!ok16(o16, d16, s) || o16 >= 0) bad++;
    end
    result("A3", "-0.6 at i = 0 to 15, sign kept", bad);

    // A4: -2.0 stays negative and ends at -1
    bad = 0;
    for (int s = 0; s < 16; s++) begin
      d16 = -16'sd32768; s16 = s; #1;
      if (!ok16(o16, d16, s) || o16 >= 0) bad++;
    end
    if (o16 !== -16'sd1) bad++;   // after the last shift (i = 15)
    result("A4", "-2.0 stays negative, ends at -1", bad);

    // A5: -1 stays -1
    bad = 0;
    for (int s = 0; s < 16; s++) begin d16 = -16'sd1; s16 = s; #1; if (o16 !== -16'sd1) bad++; end
    result("A5", "-1 stays -1 at every shift", bad);

    // A6: W = 8 exhaustive
    bad = 0;
    for (int v = -128; v < 128; v++)
      for (int s = 0; s < 8; s++) begin
        d8 = v; s8 = s; #1;
        if (o8 !== 8'(v >>> s)) bad++;
      end
    result("A6", "W = 8: all 256 inputs x 8 shifts", bad);

    // A7: N = 20, shifts 16 to 19 (the SHIFT_W bug wrapped these to 0 to 3)
    bad = 0;
    foreach (vals[k]) begin
      for (int s = 16; s < 20; s++) begin
        d20 = 20'(vals[k]) <<< 4; s20 = s; #1;      // use the full 20-bit range
        if (o20 !== 20'(d20 >>> s)) bad++;
      end
    end
    result("A7", "N = 20: i = 16 to 19, no wraparound", bad);

    // A8: engine lane width, random inputs, every shift
    bad = 0;
    void'($urandom(271));
    for (int k = 0; k < 2000; k++)
      for (int s = 0; s < 16; s++) begin
        d23 = 23'($urandom()); s23 = s; #1;
        if (o23 !== 23'(d23 >>> s)) bad++;
      end
    result("A8", "23-bit lane: 2000 random inputs x 16 shifts", bad);

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
