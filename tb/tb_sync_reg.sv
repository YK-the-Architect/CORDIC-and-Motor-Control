`timescale 1ns/1ps
// tb_sync_reg.sv : test group U4, the lane register with enable and synchronous reset (rtl/sync_reg.sv)
//   U4.1  Reset clears it, and wins over en = 1
//   U4.2  en = 0 holds the value while data_in changes; en = 1 loads data_in on the next rising edge
//   U4.3  5,000 random clocks of rst, en and data_in against a reference model, at the lane width (23 bits)

module tb_sync_reg;
  localparam int W = 23;
  logic clk = 0, rst = 0, en = 0;
  logic [W-1:0] d = '0, q;
  always #5 clk = ~clk;
  sync_reg #(.WIDTH(W)) dut (.clk(clk), .rst(rst), .en(en), .data_in(d), .data_out(q));

  int n_pass = 0, n_fail = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-56s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  initial begin
    int bad;
    bit ok;
    logic [W-1:0] model;
    void'($urandom(41));

    // U4.1 reset, also with en = 1
    @(negedge clk); en = 1; d = 23'h2AAAAA;
    @(negedge clk); ok = (q === 23'h2AAAAA);
    rst = 1; en = 1; d = 23'h155555;
    @(negedge clk); ok &= (q === '0);
    rst = 0;
    chk("U4.1", "reset clears it, and wins over en = 1", ok, $sformatf("q = %h", q));

    // U4.2 hold and load
    en = 1; d = 23'h123456;
    @(negedge clk); ok = (q === 23'h123456);
    en = 0;
    for (int k = 0; k < 8; k++) begin
      d = W'($urandom());
      @(negedge clk); if (q !== 23'h123456) ok = 0;
    end
    en = 1; d = 23'h654321;
    @(negedge clk); ok &= (q === 23'h654321);
    chk("U4.2", "en = 0 holds for 8 clocks, en = 1 loads on the next edge", ok, "");

    // U4.3 random against a model
    bad = 0;
    model = q;
    for (int k = 0; k < 5000; k++) begin
      rst = ($urandom() % 16) == 0; en = $urandom() & 1; d = W'($urandom());
      if (rst) model = '0; else if (en) model = d;
      @(negedge clk);
      if (q !== model) bad++;
    end
    rst = 0;
    chk("U4.3", "5,000 random clocks of rst, en, data_in vs a model", bad == 0, $sformatf("%0d wrong", bad));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
