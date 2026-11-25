`timescale 1ns/1ps
// tb_model_vectors.sv : dumps the engine's results so python/check_model.py can compare them with
// the bit-exact Python model (python/cordic_model.py).
//
//   EXH = 0: per mode, every combination of corner inputs, then NRAND random operations over the
//            full input range and NRAND with |x|, |y| <= 0.7. One line per operation:
//              cl rv x_in y_in z_in x_out y_out z_out ovf
//   EXH = 1: every input in every mode (W <= 8), as 256 checksums per mode:
//              B cl rv block sum      sum = (sum over the block of out * (index | 1)) mod 2^64,
//              out = x | y << W | z << 2W | ovf << 3W (W-bit fields), index = x | y << W | z << 2W
//   PIPE = 0 runs cordic_ss, PIPE = 1 runs cordic_pipe (one operation per clock).
// Output file: +OUT=<file> (default model_vectors.txt). The first line gives W, N, G.
module tb_model_vectors;
  parameter int W     = 16;
  parameter int N     = 16;
  parameter int G     = $clog2(N) + 1;
  parameter bit PIPE  = 0;
  parameter bit EXH   = 0;
  parameter int NRAND = 50000;
  parameter int SEED  = 1;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic mode_cl = 0, mode_rv = 0, start = 0, in_valid = 0;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0, x_o, y_o, z_o;
  logic out_valid, ovf_o, in_ready;
  int fd;

  if (PIPE) begin : g_pipe
    cordic_pipe #(.WIDTH(W), .ITER(N), .G(G)) dut (.clk, .rst, .in_valid, .in_ready, .mode_cl,
        .mode_rv, .x_in, .y_in, .z_in, .in_tag(4'd0), .out_valid, .out_ready(1'b1), .x_corr(x_o),
        .y_corr(y_o), .z(z_o), .ovf(ovf_o), .out_tag());
  end else begin : g_ss
    cordic_ss #(.WIDTH(W), .ITER(N), .G(G)) dut (.clk, .rst, .x_in, .y_in, .z_in, .start, .mode_cl,
        .mode_rv, .out_valid, .x_corr(x_o), .y_corr(y_o), .z(z_o), .ovf(ovf_o));
    assign in_ready = 1'b1;
  end

  // ---- what to run ----
  typedef struct { bit cl, rv; int x, y, z; } op_t;
  op_t q_in[$];                       // operations not yet answered, in order (PIPE)

  // checksums (EXH)
  localparam int NB = 256;
  localparam int BS = EXH ? (1 << (3 * W)) / NB : 1;
  longint unsigned sum [2][2][NB];
  longint unsigned n_out = 0;
  logic [W-1:0] lmask = '1;

  function automatic void record(op_t o, int xo, int yo, int zo, bit of);
    if (EXH) begin
      longint unsigned idx, packed_out;
      idx = longint'(o.x & int'(lmask)) | (longint'(o.y & int'(lmask)) << W) | (longint'(o.z & int'(lmask)) << (2 * W));
      packed_out = longint'(xo & int'(lmask)) | (longint'(yo & int'(lmask)) << W) |
                   (longint'(zo & int'(lmask)) << (2 * W)) | (longint'(of) << (3 * W));
      sum[o.cl][o.rv][idx / BS] += packed_out * (idx | 1);
    end else
      $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d", o.cl, o.rv, o.x, o.y, o.z, xo, yo, zo, of);
    n_out++;
  endfunction

  // one operation on cordic_ss: start, wait for out_valid
  task automatic run_ss(op_t o);
    @(negedge clk);
    mode_cl = o.cl; mode_rv = o.rv; x_in = W'(o.x); y_in = W'(o.y); z_in = W'(o.z); start = 1;
    @(negedge clk);
    start = 0;
    while (!out_valid) @(negedge clk);
    record(o, x_o, y_o, z_o, ovf_o);
  endtask

  // one operation on cordic_pipe: present it for one clock (in_ready stays 1: out_ready = 1)
  task automatic run_pipe(op_t o);
    @(negedge clk);
    mode_cl = o.cl; mode_rv = o.rv; x_in = W'(o.x); y_in = W'(o.y); z_in = W'(o.z); in_valid = 1;
    q_in.push_back(o);
  endtask

  always @(posedge clk) if (PIPE && !rst && out_valid) begin
    op_t o;
    if (q_in.size() == 0) $fatal(1, "result with no operation");
    o = q_in.pop_front();
    record(o, x_o, y_o, z_o, ovf_o);
  end

  task automatic run(op_t o);
    if (PIPE) run_pipe(o); else run_ss(o);
  endtask

  function automatic int sext(int v);   // low W bits as a signed number
    v = v & int'(lmask);
    return v >= (1 << (W - 1)) ? v - (1 << W) : v;
  endfunction

  initial begin
    op_t o;
    int corners[$];
    string out = "model_vectors.txt";
    void'($value$plusargs("OUT=%s", out));
    void'($urandom(SEED));
    fd = $fopen(out, "w");
    $fdisplay(fd, "# W %0d N %0d G %0d PIPE %0d EXH %0d", W, N, G, PIPE, EXH);
    repeat (3) @(negedge clk);
    rst = 0;

    if (EXH) begin
      for (int m = 0; m < 4; m++)
        for (longint k = 0; k < (longint'(1) << (3 * W)); k++) begin
          o.cl = m[1]; o.rv = m[0];
          o.x = sext(int'(k)); o.y = sext(int'(k >> W)); o.z = sext(int'(k >> (2 * W)));
          run(o);
        end
    end else begin
      // corners: zero, 1 LSB, +-0.5, +-1.0, the limits, and the quadrant edges for z
      corners = '{0, 1, -1, 2, -2};
      corners.push_back(1 << (W - 3)); corners.push_back(-(1 << (W - 3)));
      corners.push_back(1 << (W - 2)); corners.push_back(-(1 << (W - 2)));
      corners.push_back((1 << (W - 2)) - 1); corners.push_back(-(1 << (W - 2)) + 1);
      corners.push_back((1 << (W - 1)) - 1); corners.push_back(-(1 << (W - 1)));
      corners.push_back(-(1 << (W - 1)) + 1); corners.push_back((1 << (W - 2)) + 1);
      for (int m = 0; m < 4; m++)
        foreach (corners[a]) foreach (corners[b]) foreach (corners[c]) begin
          o.cl = m[1]; o.rv = m[0]; o.x = corners[a]; o.y = corners[b]; o.z = corners[c];
          run(o);
        end
      // random over the full range, then |x|, |y| <= 0.7 (no saturation, x K in range)
      for (int m = 0; m < 4; m++)
        for (int k = 0; k < 2 * NRAND; k++) begin
          o.cl = m[1]; o.rv = m[0];
          if (k < NRAND) begin
            o.x = sext($urandom()); o.y = sext($urandom()); o.z = sext($urandom());
          end else begin
            int lim;
            lim = int'(0.7 * (1 << (W - 2)));
            o.x = int'($urandom_range(2 * lim)) - lim;
            o.y = int'($urandom_range(2 * lim)) - lim;
            o.z = sext($urandom());
          end
          run(o);
        end
    end

    // drain the pipeline
    @(negedge clk);
    in_valid = 0;
    repeat (N + 10) @(negedge clk);

    if (EXH)
      for (int m = 0; m < 4; m++)
        for (int b = 0; b < NB; b++)
          $fdisplay(fd, "B %0d %0d %0d %016h", m >> 1, m & 1, b, sum[m >> 1][m & 1][b]);
    $fclose(fd);
    $display("DONE: %0d results written to %s (W = %0d, N = %0d, G = %0d, %s)", n_out, out, W, N, G,
             PIPE ? "cordic_pipe" : "cordic_ss");
    $finish;
  end
endmodule
