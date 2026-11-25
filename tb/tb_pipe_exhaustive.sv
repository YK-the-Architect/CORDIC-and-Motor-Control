`timescale 1ns/1ps
// tb_pipe_exhaustive.sv : test J10, every input in every mode at W = 8, N = 8.
// 256 x_in x 256 y_in x 256 z_in x 4 modes = 67,108,864 operations, one per clock, each compared
// bit for bit (x, y, z, ovf) with cordic_ss. Nine cordic_ss engines take turns (each needs
// 9 clocks per operation), so one of them finishes every clock and the pipeline runs at full speed.
// CUTS can be changed from the command line, as in tb_pipeline.
module tb_pipe_exhaustive #(parameter int W = 8, parameter int N = 8, parameter logic [N + 3 : 0] CUTS = '1);
  localparam int R = N + 1;                        // reference engines
  localparam int L = $countones(CUTS) + 1;         // pipeline latency
  localparam int D = (L > R ? L : R) + 2;          // each operation is compared D clocks after it goes in
  localparam int unsigned TOTAL = 32'd1 << (3 * W + 2);

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic in_valid = 0, in_ready, out_valid, p_ovf;
  logic [1:0] mode = 0;                            // {mode_cl, mode_rv}
  logic signed [W-1:0] xi = 0, yi = 0, zi = 0, p_x, p_y, p_z;
  cordic_pipe #(.WIDTH(W), .ITER(N), .TAG_W(1), .CUTS(CUTS)) dut (
    .clk, .rst, .in_valid, .in_ready, .mode_cl(mode[1]), .mode_rv(mode[0]),
    .x_in(xi), .y_in(yi), .z_in(zi), .in_tag(1'b0),
    .out_valid, .out_ready(1'b1), .x_corr(p_x), .y_corr(p_y), .z(p_z), .ovf(p_ovf), .out_tag());

  logic [R-1:0] r_start = '0, r_valid, r_ovf;
  logic signed [W-1:0] r_x [R], r_y [R], r_z [R];
  for (genvar e = 0; e < R; e++) begin : g_ref
    cordic_ss #(.WIDTH(W), .ITER(N)) u_ref (
      .clk, .rst, .x_in(xi), .y_in(yi), .z_in(zi), .start(r_start[e]),
      .mode_cl(mode[1]), .mode_rv(mode[0]), .out_valid(r_valid[e]),
      .x_corr(r_x[e]), .y_corr(r_y[e]), .z(r_z[e]), .ovf(r_ovf[e]));
  end

  // results as plain bit vectors {x, y, z, ovf}, kept in rings of 64 by operation number
  logic [3 * W : 0] ref_ring [64], pipe_ring [64];
  bit          ref_has [64], pipe_has [64];
  int unsigned idx_e [R];
  int unsigned nxt = 0;           // next operation to put in
  int unsigned tick = 0;          // clocks since operation 0 went in
  int unsigned n_out = 0, n_cmp = 0, n_bad = 0, n_missing = 0, n_notready = 0;
  bit started = 0;

  // operation nxt goes in at the next rising edge, on the pipeline and on engine nxt % R
  always @(negedge clk) begin
    if (!rst && nxt < TOTAL) begin
      mode     = nxt[3 * W + 1 : 3 * W];
      xi       = nxt[3 * W - 1 : 2 * W];
      yi       = nxt[2 * W - 1 : W];
      zi       = nxt[W - 1 : 0];
      in_valid = 1;
      r_start  = R'(1) << (nxt % R);
    end else begin
      in_valid = 0;
      r_start  = '0;
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      for (int e = 0; e < R; e++)
        if (r_valid[e]) begin
          ref_ring[idx_e[e] % 64] = {r_x[e], r_y[e], r_z[e], r_ovf[e]};
          ref_has[idx_e[e] % 64]  = 1;
        end
      if (out_valid) begin
        pipe_ring[n_out % 64] = {p_x, p_y, p_z, p_ovf};
        pipe_has[n_out % 64]  = 1;
        n_out++;
      end
      if (in_valid) begin             // operation nxt is taken at this edge
        if (!in_ready) n_notready++;
        idx_e[nxt % R] = nxt;
        nxt++;
        started = 1;
      end
      if (started) begin
        if (tick >= D && tick - D < TOTAL) begin
          int unsigned j, s;
          j = tick - D;
          s = j % 64;
          if (!ref_has[s] || !pipe_has[s]) n_missing++;
          else if (ref_ring[s] != pipe_ring[s]) begin
            n_bad++;
            if (n_bad <= 8)
              $display("  mismatch, op %0d (mode %0d, x %h, y %h, z %h): pipeline %h, cordic_ss %h  ({x, y, z, ovf} in hex)",
                       j, j[3 * W + 1 : 3 * W], j[3 * W - 1 : 2 * W], j[2 * W - 1 : W], j[W - 1 : 0],
                       pipe_ring[s], ref_ring[s]);
          end
          n_cmp++;
          ref_has[s]  = 0;
          pipe_has[s] = 0;
        end
        tick++;
        if (tick - D == TOTAL) begin
          bit ok;
          ok = n_bad == 0 && n_missing == 0 && n_notready == 0 && n_cmp == TOTAL;
          $display("cordic_pipe W = %0d, N = %0d, CUTS = %b, latency %0d clocks", W, N, CUTS, L);
          $display("%s J10  every input in all 4 modes: %0d operations   %0d different, %0d missing",
                   ok ? "PASS" : "FAIL", n_cmp, n_bad, n_missing);
          $display("DONE: %0d passed, %0d failed", ok, !ok);
          $finish;
        end
      end
    end
  end

  initial begin
    repeat (3) @(posedge clk);
    rst <= 0;
  end
endmodule
