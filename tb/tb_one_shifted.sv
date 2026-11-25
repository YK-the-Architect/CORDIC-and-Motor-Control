`timescale 1ns/1ps
// tb_one_shifted.sv : test group U3, the 2^-i constant that linear mode adds to the z lane
// (rtl/one_shifted.sv)
//   U3.1  As the datapath uses it (23-bit lane, 1.0 at bit 20, ITER 16): output = 2^(20 - i) for every i
//   U3.2  Default format (W 8, 1.0 at bit 7, ITER 8): output = 2^(7 - i) for every i
//   U3.3  More iterations than fraction bits (W 8, ITER 16): 2^-i becomes 0 for i > 7 and never wraps

module tb_one_shifted;
  logic [3:0]  i_lane;  logic [22:0] o_lane;
  logic [2:0]  i_def;   logic [7:0]  o_def;
  logic [3:0]  i_long;  logic [7:0]  o_long;
  one_shifted #(.WIDTH(23), .ITER(16), .FRAC(20)) dut_lane (.i(i_lane), .one_l_shift(o_lane));
  one_shifted #(.WIDTH(8),  .ITER(8))                dut_def  (.i(i_def),  .one_l_shift(o_def));
  one_shifted #(.WIDTH(8),  .ITER(16))               dut_long (.i(i_long), .one_l_shift(o_long));

  int n_pass = 0, n_fail = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-56s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad;

    bad = 0;
    for (int k = 0; k < 16; k++) begin
      i_lane = 4'(k); #1;
      if (o_lane !== 23'(1) << (20 - k)) bad++;
    end
    chk("U3.1", "23-bit lane, 1.0 at bit 20: 2^(20 - i) for i = 0 to 15", bad == 0, $sformatf("%0d wrong", bad));

    bad = 0;
    for (int k = 0; k < 8; k++) begin
      i_def = 3'(k); #1;
      if (o_def !== 8'(1) << (7 - k)) bad++;
    end
    chk("U3.2", "W 8, 1.0 at bit 7: 2^(7 - i) for i = 0 to 7", bad == 0, $sformatf("%0d wrong", bad));

    bad = 0;
    for (int k = 0; k < 16; k++) begin
      i_long = 4'(k); #1;
      if (o_long !== (k <= 7 ? 8'(1) << (7 - k) : 8'd0)) bad++;
    end
    chk("U3.3", "W 8, ITER 16: 0 for i > 7, no wrap", bad == 0, $sformatf("%0d wrong", bad));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
