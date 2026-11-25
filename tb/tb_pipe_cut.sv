`timescale 1ns/1ps
// tb_pipe_cut.sv : test group U6, one register rank of the pipelined engine (rtl/pipe_cut.sv)
// Three ranks side by side, all driven by the same random stimulus every clock (rst, adv, v_d, d):
//   REG 1, EN 1 (the default: stall support)   REG 1, EN 0 (loads every clock)   REG 0 (a wire)
//   U6.1  REG 0 is a wire: q = d and v_q = v_d at all times, with no clock involved
//   U6.2  REG 1, EN 1: v_q takes v_d when adv = 1 and holds when adv = 0; q takes d only when adv and v_d
//         are both 1, so a bubble or a stall leaves it alone; reset clears v_q. 5,000 random clocks vs a model
//   U6.3  REG 1, EN 0: v_q the same; q takes d on every clock. 5,000 random clocks vs a model
//   U6.4  A 10-clock stall (adv = 0) while v_d and d change every clock: the EN 1 rank holds v_q and q,
//         the EN 0 rank holds v_q (its q keeps loading, as intended: that rank has no stall support)

module tb_pipe_cut;
  localparam int W = 23;
  logic clk = 0, rst = 1, adv = 0, v_d = 0;
  logic [W-1:0] d = '0;
  logic v_en, v_free, v_wire;
  logic [W-1:0] q_en, q_free, q_wire;
  always #5 clk = ~clk;

  pipe_cut #(.W(W), .REG(1), .EN(1)) r_en   (.clk, .rst, .adv, .v_d, .d, .v_q(v_en),   .q(q_en));
  pipe_cut #(.W(W), .REG(1), .EN(0)) r_free (.clk, .rst, .adv, .v_d, .d, .v_q(v_free), .q(q_free));
  pipe_cut #(.W(W), .REG(0), .EN(1)) r_wire (.clk, .rst, .adv, .v_d, .d, .v_q(v_wire), .q(q_wire));

  int n_pass = 0, n_fail = 0;

  task automatic chk(input string id, input string what, input bit ok, input string detail);
    $display("%s %-5s %-58s %s", ok ? "PASS" : "FAIL", id, what, detail);
    if (ok) n_pass++; else n_fail++;
  endtask

  // reference model of the two registered ranks
  logic         mv_en, mv_free;
  logic [W-1:0] mq_en, mq_free;
  bit           known_en;                 // q of the EN 1 rank is X until its first load

  task automatic model_edge();
    if (rst) begin mv_en = 0; mv_free = 0; end
    else if (adv) begin mv_en = v_d; mv_free = v_d; end
    if (adv && v_d) begin mq_en = d; known_en = 1; end      // data has no reset
    mq_free = d;
  endtask

  initial begin
    int bad_w, bad_e, bad_f;
    bit ok;
    logic v_hold, vf_hold;
    logic [W-1:0] q_hold;
    void'($urandom(61));
    known_en = 0;

    // U6.1 the wire, with no clock edges at all
    bad_w = 0;
    for (int k = 0; k < 2000; k++) begin
      v_d = $urandom() & 1; d = W'($urandom()); #0.1;
      if (v_wire !== v_d || q_wire !== d) bad_w++;
    end
    chk("U6.1", "REG 0 is a wire: q = d, v_q = v_d (2,000 values, no clock)", bad_w == 0,
        $sformatf("%0d wrong", bad_w));

    // reset, then random clocks against the model
    @(negedge clk); rst = 1; adv = 1; v_d = 0;
    model_edge();
    @(negedge clk); rst = 0;
    bad_e = 0; bad_f = 0;
    for (int k = 0; k < 5000; k++) begin
      rst = ($urandom() % 50) == 0;
      adv = ($urandom() % 4) != 0;          // stalls a quarter of the time
      v_d = ($urandom() % 3) != 0;          // bubbles a third of the time
      d = W'($urandom());
      model_edge();
      @(negedge clk);
      if (v_en !== mv_en || (known_en && q_en !== mq_en)) bad_e++;
      if (v_free !== mv_free || q_free !== mq_free) bad_f++;
    end
    rst = 0;
    chk("U6.2", "REG 1, EN 1: 5,000 random clocks of rst, adv, v_d, d vs a model", bad_e == 0,
        $sformatf("%0d wrong", bad_e));
    chk("U6.3", "REG 1, EN 0: 5,000 random clocks of rst, adv, v_d, d vs a model", bad_f == 0,
        $sformatf("%0d wrong", bad_f));

    // U6.4 a long stall: load a real value first, then adv = 0 for 10 clocks
    adv = 1; v_d = 1; d = 23'h3C3C3C;
    @(negedge clk);
    v_hold = v_en; q_hold = q_en; vf_hold = v_free;
    ok = (v_hold === 1'b1) && (q_hold === 23'h3C3C3C);
    adv = 0;
    for (int k = 0; k < 10; k++) begin
      v_d = $urandom() & 1; d = W'($urandom());
      @(negedge clk);
      if (v_en !== v_hold || q_en !== q_hold || v_free !== vf_hold) ok = 0;
      if (q_free !== d) ok = 0;
    end
    chk("U6.4", "10-clock stall: EN 1 rank holds v_q and q, EN 0 rank holds v_q", ok, "");

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
