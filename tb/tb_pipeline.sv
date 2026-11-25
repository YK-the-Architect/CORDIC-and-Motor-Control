`timescale 1ns/1ps
// tb_pipeline.sv : test group J, the pipelined engine (cordic_pipe), W = 16, N = 16.
// Every result is checked bit for bit (x, y, z, ovf and tag) against the iterative engine
// (cordic_ss) on the same inputs, so the accuracy shown in groups A to I carries over.
//   J1  40,000 random operations, all four modes, back to back       -> identical to cordic_ss
//   J2  Corner inputs: 0, +-1 LSB, +-0.5, +-1.0, limits, key angles   -> identical
//   J3  Latency and throughput                                       -> L clocks, then one result per clock
//   J4  Random bubbles and stalls (in_valid, out_ready low 30%)      -> nothing lost, repeated or reordered
//   J5  A stalled result holds                                       -> outputs and tag stable until taken
//   J6  Long stall: out_ready low for 3 L clocks, inputs keep coming -> takes L + 1, in_ready drops, drains in order
//   J7  Reset with operations in flight                              -> nothing comes out afterwards
//   J8  Dependent operations (external data hazard): each result is the input of the next
//       operation in its chain; 1 to 2 L chains interleaved          -> identical, chains wait for their data
//   J9  Tags                                                         -> every result carries its operation's tag
// L = (number of 1s in CUTS) + 1. CUTS can be set from the command line to run all of this on
// any pipeline depth (Verilator: -GCUTS=20\'h00001; VCS: -pvalue+tb_pipeline.CUTS=1).
module tb_pipeline #(parameter int W = 16, parameter int N = 16, parameter logic [N + 3 : 0] CUTS = '1);
  localparam int R  = $countones(CUTS);          // register ranks before the output register
  localparam int L  = R + 1;                     // latency in clocks
  localparam int TW = 6;                         // tag width: up to 64 chains in J8

  logic clk = 0, rst;
  always #5 clk = ~clk;

  // reference: the iterative engine, with the names tb_common.svh expects
  logic start, mode_cl, mode_rv, out_valid, ovf, ready;
  logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) ref_eng (.*);

  // device under test
  logic p_in_valid = 0, p_in_ready, p_mode_cl = 0, p_mode_rv = 0, p_out_valid, p_out_ready = 1, p_ovf;
  logic signed [W-1:0] p_x_in = 0, p_y_in = 0, p_z_in = 0, p_x, p_y, p_z;
  logic [TW-1:0] p_in_tag = 0, p_out_tag;
  cordic_pipe #(.WIDTH(W), .ITER(N), .TAG_W(TW), .CUTS(CUTS)) dut (
    .clk, .rst, .in_valid(p_in_valid), .in_ready(p_in_ready), .mode_cl(p_mode_cl), .mode_rv(p_mode_rv),
    .x_in(p_x_in), .y_in(p_y_in), .z_in(p_z_in), .in_tag(p_in_tag),
    .out_valid(p_out_valid), .out_ready(p_out_ready), .x_corr(p_x), .y_corr(p_y), .z(p_z),
    .ovf(p_ovf), .out_tag(p_out_tag));

  `include "tb_common.svh"

  typedef struct packed { logic cl, rv; logic signed [31:0] x, y, z; logic [31:0] tag; } op_t;
  typedef struct packed { logic signed [31:0] x, y, z; logic [31:0] tag; logic of; } rs_t;

  op_t cur;                         // the operation on the pipeline inputs
  op_t refq [$];                    // taken by the pipeline, waiting for the reference
  rs_t expq [$], gotq [$];          // reference results and pipeline results, in order
  rs_t o, held_r;
  int  n_acc = 0, n_got = 0, n_cmp = 0, n_bad = 0;
  int  n_unstable = 0, n_held = 0, n_inwait = 0, cyc = 0;
  int  first_out = -1, last_out = -1, n_out_win = 0;
  bit  track = 1;                   // J7 turns the scoreboard off around its reset
  bit  taken = 0;                   // the operation on the inputs was taken at the last edge
  bit  held = 0;                    // a result was left waiting at the last edge
  bit  ch_busy [64];                // J8: the chain's last operation is still in the pipeline
  rs_t ch_last [64];                // J8: the chain's last result

  // both handshakes, sampled at the clock edge
  always @(posedge clk) begin
    cyc++;
    taken = p_in_valid && p_in_ready && !rst;
    if (rst) held = 0;
    else begin
      if (taken && track) begin refq.push_back(cur); n_acc++; end
      if (p_in_valid && !p_in_ready) n_inwait++;
      o = '{p_x, p_y, p_z, p_out_tag, p_ovf};
      if (held && (!p_out_valid || o != held_r)) n_unstable++;     // J5
      held   = p_out_valid && !p_out_ready;
      held_r = o;
      if (held) n_held++;
      if (p_out_valid && p_out_ready) begin
        if (track) begin gotq.push_back(o); n_got++; end
        if (first_out < 0) first_out = cyc;
        last_out = cyc;
        n_out_win++;
        ch_busy[p_out_tag] = 0;
        ch_last[p_out_tag] = o;
      end
    end
  end

  // the reference runs every taken operation through cordic_ss, in order
  initial begin : ref_side
    op_t r; int xo, yo, zo, lat; bit of;
    forever begin
      while (refq.size() == 0) @(negedge clk);
      r = refq.pop_front();
      op(r.cl, r.rv, r.x, r.y, r.z, xo, yo, zo, of, lat);
      expq.push_back('{xo, yo, zo, r.tag, of});
    end
  end

  // compare in order
  always @(negedge clk) begin
    while (expq.size() > 0 && gotq.size() > 0) begin
      rs_t e, g;
      e = expq.pop_front();
      g = gotq.pop_front();
      n_cmp++;
      if (e != g) begin
        n_bad++;
        if (n_bad <= 8)
          $display("  mismatch at %0d: pipeline (%0d, %0d, %0d, ovf %0d, tag %0d), cordic_ss (%0d, %0d, %0d, ovf %0d, tag %0d)",
                   n_cmp, g.x, g.y, g.z, g.of, g.tag, e.x, e.y, e.z, e.of, e.tag);
      end
    end
  end

  // wait until every taken operation has been compared
  task automatic drain();
    int t = 0;
    while (n_cmp < n_acc && t < 5000000) begin @(negedge clk); t++; end
  endtask

  // stimulus
  int bubble_pct = 0, stall_pct = 0, seq = 0;
  bit force_stall = 0;
  always @(negedge clk) p_out_ready = !force_stall && (int'($urandom_range(99)) >= stall_pct);

  function automatic int rnd_val(input bit wide);   // a random code: full range or within +-1.0
    if (wide) return int'($urandom_range((1 << W) - 1)) - (1 << (W - 1));
    return int'($urandom_range(1 << (W - 1))) - (1 << (W - 2));
  endfunction

  function automatic op_t rnd_op();
    op_t r; bit wide;
    wide  = $urandom_range(1);
    r.cl  = $urandom_range(1);
    r.rv  = $urandom_range(1);
    r.x   = rnd_val(wide);
    r.y   = rnd_val(wide);
    r.z   = rnd_val(1);
    r.tag = seq % (1 << TW);
    return r;
  endfunction

  task automatic present(input op_t r);
    cur = r;
    p_mode_cl = r.cl; p_mode_rv = r.rv;
    p_x_in = r.x; p_y_in = r.y; p_z_in = r.z; p_in_tag = r.tag;
    p_in_valid = 1;
    seq++;
  endtask

  // offer n operations (random, or from the corner list); in_valid drops for bubbles, and an
  // offered operation holds until it is taken
  op_t corners [$];
  task automatic send(input int n, input bit from_list);
    int sent = 0, ci = 0;
    while (sent < n) begin
      @(negedge clk);
      if (p_in_valid) begin
        if (!taken) continue;
        sent++;
        p_in_valid = 0;
        if (sent == n) break;
      end
      if (int'($urandom_range(99)) < bubble_pct) continue;
      if (from_list) begin
        present(corners[ci]);
        ci++;
      end else present(rnd_op());
    end
  endtask

  // J8: the next operation of chain c is built from the chain's last result
  function automatic op_t next_in_chain(input int c, input int s);
    op_t r; int x, y, lim;
    lim = 1 << (W - 2);
    x = ch_last[c].x;
    y = ch_last[c].y;
    while (x > lim || x < -lim || y > lim || y < -lim) begin x = x / 2; y = y / 2; end
    if (x == 0 && y == 0) x = lim / 2;
    case (s % 4)
      0:       begin r.cl = 0; r.rv = 0; r.z = rnd_val(1);     end   // rotate (Park-like)
      1:       begin r.cl = 0; r.rv = 1; r.z = 0;              end   // vectoring
      2:       begin r.cl = 1; r.rv = 0; r.z = rnd_val(1) / 2; end   // multiply-add
      default: begin r.cl = 1; r.rv = 1; r.z = 0;              end   // divide
    endcase
    r.x = x; r.y = y; r.tag = c;
    return r;
  endfunction

  // M chains of K operations, round robin over the chains whose data is back
  task automatic chains(input int M, input int K, output int clocks);
    int left [64], step [64];
    int c, c0, busy;
    bit found;
    for (int k = 0; k < M; k++) begin
      left[k] = K; step[k] = 0; ch_busy[k] = 0;
      ch_last[k] = '{rnd_val(0), rnd_val(0), 0, k, 0};
    end
    c0 = cyc; c = 0;
    forever begin
      @(negedge clk);
      if (p_in_valid) begin
        if (!taken) continue;
        p_in_valid = 0;
      end
      found = 0;
      for (int k = 0; k < M && !found; k++)
        if (!ch_busy[(c + k) % M] && left[(c + k) % M] > 0) begin found = 1; c = (c + k) % M; end
      if (found) begin
        present(next_in_chain(c, step[c]));
        ch_busy[c] = 1; left[c]--; step[c]++;
        c = (c + 1) % M;
      end else begin
        busy = 0;
        for (int k = 0; k < M; k++) if (ch_busy[k] || left[k] > 0) busy = 1;
        if (!busy) break;
      end
    end
    clocks = cyc - c0;
  endtask

  initial begin
    int lat, took, nv, bad0, unst0, clocks, m_list [7];
    bit full, ok;
    string thr;
    rst = 1; start = 0; mode_cl = 0; mode_rv = 0; x_in = 0; y_in = 0; z_in = 0;
    repeat (3) @(negedge clk);
    rst = 0;
    $display("cordic_pipe W = %0d, N = %0d, CUTS = %b: %0d register ranks, latency %0d clocks", W, N, CUTS, R, L);

    // J1
    bad0 = n_bad;
    send(40000, 0);
    drain();
    result("J1", "40,000 random operations, back to back", n_bad == bad0 && n_cmp == n_acc,
           $sformatf("%0d compared, %0d different", n_cmp, n_bad - bad0));

    // J2
    begin
      int vx [12], vz [12];
      vx = '{0, 1, -1, 2, 1 << (W - 3), -(1 << (W - 3)), 1 << (W - 2), -(1 << (W - 2)), WMAX, WMIN, WMAX - 1, WMIN + 1};
      vz = '{0, 1, -1, deg2z(30.0), deg2z(45.0), deg2z(90.0), deg2z(-90.0), deg2z(91.0), deg2z(135.0),
             deg2z(-135.0), WMIN, WMAX};
      corners = {};
      for (int m = 0; m < 4; m++)
        foreach (vx[a]) foreach (vx[b]) foreach (vz[c])
          corners.push_back('{m[1], m[0], vx[a], vx[b], vz[c], corners.size() % (1 << TW)});
      bad0 = n_bad;
      send(corners.size(), 1);
      drain();
      result("J2", $sformatf("%0d corner inputs, every mode", corners.size()), n_bad == bad0 && n_cmp == n_acc,
             $sformatf("%0d different", n_bad - bad0));
    end

    // J3: latency into an empty pipeline, then 1,000 back to back
    @(negedge clk);
    present(rnd_op());
    @(negedge clk);
    p_in_valid = 0; lat = 1;
    while (!p_out_valid && lat < 4 * L + 10) begin @(negedge clk); lat++; end
    drain();
    first_out = -1; n_out_win = 0; nv = n_inwait;
    send(1000, 0);
    drain();
    result("J3", $sformatf("latency %0d clocks, then one result per clock", L),
           lat == L && n_out_win == 1000 && last_out - first_out == 999 && n_inwait == nv,
           $sformatf("latency %0d, 1,000 results in %0d clocks", lat, last_out - first_out + 1));

    // J4, J5
    bubble_pct = 30; stall_pct = 30;
    bad0 = n_bad; unst0 = n_unstable; took = n_acc; nv = n_got;
    send(40000, 0);
    drain();
    bubble_pct = 0; stall_pct = 0;
    result("J4", "40,000 with 30% bubbles and 30% stalls", n_bad == bad0 && n_cmp == n_acc && n_got == n_acc,
           $sformatf("%0d taken, %0d out, %0d different", n_acc - took, n_got - nv, n_bad - bad0));
    result("J5", "a stalled result holds until taken", n_unstable == unst0,
           $sformatf("%0d stalled clocks, %0d changes", n_held, n_unstable - unst0));

    // J6: long stall while inputs keep coming
    bad0 = n_bad; took = n_acc;
    force_stall = 1;
    fork
      send(L + 1 + 20, 0);
      begin
        repeat (3 * L + 2) @(negedge clk);
        took = n_acc - took;
        full = !p_in_ready;
        force_stall = 0;
      end
    join
    drain();
    result("J6", $sformatf("stall of %0d clocks: takes L + 1 = %0d, then waits", 3 * L + 2, L + 1),
           took == L + 1 && full && n_bad == bad0 && n_cmp == n_acc,
           $sformatf("took %0d, in_ready low: %0d", took, full));

    // J7: reset with operations in flight
    track = 0;
    send(10, 0);
    @(negedge clk); rst = 1;
    @(negedge clk); rst = 0;
    nv = 0;
    repeat (3 * L + 2) begin @(negedge clk); if (p_out_valid) nv++; end
    track = 1;
    result("J7", "reset with operations in flight", nv == 0, $sformatf("%0d results after reset", nv));

    // J8: dependent chains, no stalls (throughput), then with stalls
    m_list = '{1, 2, 4, 8, L, L + 1, 2 * L};
    bad0 = n_bad; ok = 1; thr = "";
    foreach (m_list[k]) begin
      int kk;
      kk = 2000 / m_list[k];
      if (kk < 20) kk = 20;
      chains(m_list[k], kk, clocks);
      thr = {thr, $sformatf(" %0d:%0.2f", m_list[k], real'(m_list[k] * kk) / clocks)};
    end
    stall_pct = 30;
    chains(8, 250, clocks);
    stall_pct = 0;
    drain();
    result("J8", "dependent chains (1 to 2 L), then 8 with stalls", n_bad == bad0 && n_cmp == n_acc,
           $sformatf("results per clock, chains:%s", thr));

    // J9: the scoreboard compares tags on every result above
    result("J9", "every result carries its operation's tag", n_bad == 0 && n_cmp == n_acc,
           $sformatf("%0d results checked", n_cmp));

    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end

  initial begin
    #(64'd2_000_000_000);
    $display("TIMEOUT");
    $finish;
  end
endmodule
