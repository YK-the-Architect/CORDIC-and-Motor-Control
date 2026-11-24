`timescale 1ns/1ps
// tb_addsub.sv : test group B, add/sub and its overflow flag (W = 16)
//   B1  Random a and b, both operations -> matches integer math (and the flag is right)
//   B2  +32767 + 1                      -> overflow = 1
//   B3  -32768 - 1                      -> overflow = 1
//   B4  0 - (-32768)                    -> overflow = 1
//   B5  +32767 + (-32768); 0 + 0; 0 - 0 -> overflow = 0

module tb_addsub;
  logic signed [15:0] a, b, r;
  logic op, ovf;
  add_sub #(.WIDTH(16)) dut (.a(a), .b(b), .add_sub(op), .sum_diff(r), .overflow(ovf));

  int n_pass = 0, n_fail = 0;

  // drive one case; returns 1 if the result and the flag match integer math
  function automatic bit expect_ok(int ea, int eb, bit sub, output int got_r, output bit got_o);
    int full;
    full = sub ? ea - eb : ea + eb;
    got_r = r; got_o = ovf;
    return (r == 16'(full)) && (ovf == (full > 32767 || full < -32768));
  endfunction

  task automatic one(input string id, input string what, input int ea, input int eb, input bit sub,
                     input bit want_ovf);
    int gr; bit go, ok;
    a = ea; b = eb; op = sub; #1;
    ok = expect_ok(ea, eb, sub, gr, go) && (go == want_ovf);
    $display("%s %-3s %-30s result %6d  overflow %0d", ok ? "PASS" : "FAIL", id, what, gr, go);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad, gr; bit go;
    bad = 0;
    void'($urandom(11));
    for (int k = 0; k < 20000; k++) begin
      int ea, eb; bit sub;
      ea = $signed(16'($urandom())); eb = $signed(16'($urandom())); sub = $urandom() & 1;
      a = ea; b = eb; op = sub; #1;
      if (!expect_ok(ea, eb, sub, gr, go)) bad++;
    end
    $display("%s B1  20,000 random a, b, add and subtract: %0d mismatches", bad == 0 ? "PASS" : "FAIL", bad);
    if (bad == 0) n_pass++; else n_fail++;

    one("B2", "+32767 + 1",           32767,      1, 0, 1);
    one("B3", "-32768 - 1",          -32768,      1, 1, 1);
    one("B4", "0 - (-32768)",              0, -32768, 1, 1);
    one("B5", "+32767 + (-32768)",     32767, -32768, 0, 0);
    one("B5", "0 + 0",                     0,      0, 0, 0);
    one("B5", "0 - 0",                     0,      0, 1, 0);

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
