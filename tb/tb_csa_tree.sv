`timescale 1ns/1ps
// tb_csa_tree.sv : test group U5, the carry-save adder tree (rtl/csa_tree.sv). cordic_pipe uses it for
// x K and y K: N shifted copies are reduced to two numbers, s and c, with no carry chain.
// s + c (mod 2^W) must equal the sum of the N inputs (mod 2^W).
//   U5.1  N = 8, W = 42, the size cordic_pipe uses (7 shifted copies + 1 correction): 20,000 random sets
//   U5.2  N = 1, 2, 3, 4, 5 at W = 42 (pass-through, one group, groups with leftovers): 20,000 random sets each
//   U5.3  N = 3 and N = 4 at W = 4: every input combination (4,096 and 65,536)
//   U5.4  Extremes at N = 8, W = 42: all ones (the sum wraps), all zeros, alternating bit patterns

module csa_check #(
  parameter int    N     = 3,
  parameter int    W     = 8,
  parameter int    NRAND = 20000,
  parameter bit    EXH   = 0,      // every input combination (N * W must be small)
  parameter bit    EXTR  = 0,      // also the extreme patterns (U5.4)
  parameter string ID    = "U5.2"
)(
  output int n_pass,
  output int n_fail,
  output bit done
);
  logic [N-1:0][W-1:0] in;
  logic [W-1:0] s, c;
  csa_tree #(.N(N), .W(W)) dut (.in(in), .s(s), .c(c));

  function automatic logic [W-1:0] total();
    logic [W-1:0] acc;
    acc = '0;
    for (int k = 0; k < N; k++) acc += in[k];
    return acc;
  endfunction

  // apply the current inputs, return 1 if s + c is the sum
  function automatic bit ok_now();
    return W'(s + c) === total();
  endfunction

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-58s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad, cases;
    n_pass = 0; n_fail = 0; done = 0;
    #1;
    bad = 0; cases = 0;
    if (EXH) begin
      for (longint k = 0; k < (longint'(1) << (N * W)); k++) begin
        in = (N * W)'(k); #1;
        if (!ok_now()) bad++;
        cases++;
      end
      chk(ID, $sformatf("N = %0d, W = %0d: every input combination", N, W), bad == 0,
          $sformatf("%0d cases, %0d wrong", cases, bad));
    end else begin
      for (int k = 0; k < NRAND; k++) begin
        for (int j = 0; j < N; j++) in[j] = W'({$urandom(), $urandom()});
        #1;
        if (!ok_now()) bad++;
        cases++;
      end
      chk(ID, $sformatf("N = %0d, W = %0d: random sets", N, W), bad == 0,
          $sformatf("%0d cases, %0d wrong", cases, bad));
    end
    if (EXTR) begin
      bad = 0;
      for (int j = 0; j < N; j++) in[j] = '1;                        #1; if (!ok_now()) bad++;
      for (int j = 0; j < N; j++) in[j] = '0;                        #1; if (!ok_now()) bad++;
      for (int j = 0; j < N; j++) in[j] = {(W + 1) / 2{2'b01}};      #1; if (!ok_now()) bad++;
      for (int j = 0; j < N; j++) in[j] = {(W + 1) / 2{2'b10}};      #1; if (!ok_now()) bad++;
      for (int j = 0; j < N; j++) in[j] = j[0] ? {(W + 1) / 2{2'b01}} : {(W + 1) / 2{2'b10}};
      #1; if (!ok_now()) bad++;
      chk("U5.4", $sformatf("N = %0d, W = %0d: all ones, all zeros, alternating bits", N, W), bad == 0,
          $sformatf("%0d wrong", bad));
    end
    done = 1;
  end
endmodule

module tb_csa_tree;
  localparam int NI = 8;
  int  p [NI], f [NI];
  bit  d [NI];
  csa_check #(.N(8), .W(42), .EXTR(1), .ID("U5.1")) c8  (.n_pass(p[0]), .n_fail(f[0]), .done(d[0]));
  csa_check #(.N(1), .W(42))                         c1  (.n_pass(p[1]), .n_fail(f[1]), .done(d[1]));
  csa_check #(.N(2), .W(42))                         c2  (.n_pass(p[2]), .n_fail(f[2]), .done(d[2]));
  csa_check #(.N(3), .W(42))                         c3  (.n_pass(p[3]), .n_fail(f[3]), .done(d[3]));
  csa_check #(.N(4), .W(42))                         c4  (.n_pass(p[4]), .n_fail(f[4]), .done(d[4]));
  csa_check #(.N(5), .W(42))                         c5  (.n_pass(p[5]), .n_fail(f[5]), .done(d[5]));
  csa_check #(.N(3), .W(4), .EXH(1), .ID("U5.3"))    e3  (.n_pass(p[6]), .n_fail(f[6]), .done(d[6]));
  csa_check #(.N(4), .W(4), .EXH(1), .ID("U5.3"))    e4  (.n_pass(p[7]), .n_fail(f[7]), .done(d[7]));

  initial begin
    int tp, tf;
    void'($urandom(51));
    wait (d[0] && d[1] && d[2] && d[3] && d[4] && d[5] && d[6] && d[7]);
    tp = 0; tf = 0;
    for (int k = 0; k < NI; k++) begin tp += p[k]; tf += f[k]; end
    $display("DONE: %0d passed, %0d failed", tp, tf);
    $finish;
  end
endmodule
