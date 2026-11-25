`timescale 1ns/1ps
// tb_mux.sv : test group U2, the 2-to-1 multiplexer (rtl/mux.sv, module cordic_mux)
// In the datapath it picks the new inputs (sel = init = 1) or the next iteration (sel = 0) for each lane,
// and atan(2^-i) or 2^-i for the z lane.
//   U2.1  At the lane width (23 bits): sel = 1 gives sel1, sel = 0 gives sel0, 10,000 random pairs
//   U2.2  Extremes pass unchanged with their sign: most negative, most positive, 0 and -1, both ways
//   U2.3  At W = 8: every pair of inputs with both values of sel (131,072 cases)

module tb_mux;
  localparam int W = 23;
  logic signed [W-1:0] a1, a0, y;
  logic s;
  cordic_mux #(.WIDTH(W)) dut (.sel1(a1), .sel0(a0), .sel(s), .mux_out(y));

  logic signed [7:0] b1, b0, y8;
  logic s8;
  cordic_mux #(.WIDTH(8)) dut8 (.sel1(b1), .sel0(b0), .sel(s8), .mux_out(y8));

  int n_pass = 0, n_fail = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-56s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad;
    logic signed [W-1:0] ext [4];
    void'($urandom(21));

    // U2.1 random pairs at the lane width
    bad = 0;
    for (int k = 0; k < 10000; k++) begin
      a1 = W'($urandom()); a0 = W'($urandom()); s = $urandom() & 1; #1;
      if (y !== (s ? a1 : a0)) bad++;
    end
    chk("U2.1", "23 bits: 10,000 random pairs, both values of sel", bad == 0, $sformatf("%0d wrong", bad));

    // U2.2 extremes
    ext[0] = {1'b1, {(W-1){1'b0}}};       // most negative
    ext[1] = {1'b0, {(W-1){1'b1}}};       // most positive
    ext[2] = '0;
    ext[3] = '1;                          // -1
    bad = 0;
    for (int p = 0; p < 4; p++)
      for (int q = 0; q < 4; q++) begin
        a1 = ext[p]; a0 = ext[q];
        s = 1; #1; if (y !== ext[p] || (y < 0) != (ext[p] < 0)) bad++;
        s = 0; #1; if (y !== ext[q] || (y < 0) != (ext[q] < 0)) bad++;
      end
    chk("U2.2", "extremes (min, max, 0, -1) pass with their sign", bad == 0, $sformatf("%0d wrong", bad));

    // U2.3 exhaustive at W = 8
    bad = 0;
    for (int p = 0; p < 256; p++)
      for (int q = 0; q < 256; q++)
        for (int r = 0; r < 2; r++) begin
          b1 = 8'(p); b0 = 8'(q); s8 = r[0]; #1;
          if (y8 !== (r[0] ? 8'(p) : 8'(q))) bad++;
        end
    chk("U2.3", "W = 8: every pair, both values of sel (131,072 cases)", bad == 0, $sformatf("%0d wrong", bad));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
