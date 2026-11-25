`timescale 1ns/1ps
// compare/tb_mult_rot.sv : accuracy of the multiplier-based rotation (mult_rot) and of CORDIC
// (cordic_pipe, rotation mode) on the same inputs, against real math, W = 16.
//   M1  (1, 0) at 4,096 angles (as E9)
//   M2  100,000 random vectors (length up to 1.4) at random angles
// Errors in LSBs of x and y (Q2.14). Results that saturate are not counted.
module tb_mult_rot;
  localparam int W = 16;
  localparam real PI = 3.14159265358979323846, QXY = 2.0 ** (W - 2), TURN = 2.0 ** W;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic in_valid = 0, m_valid, c_valid, c_ready, c_ovf;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0, mx, my, cx, cy, cz;
  logic [3:0] c_tag;
  mult_rot #(.WIDTH(W)) u_mult (.clk, .rst, .in_valid, .x_in, .y_in, .z_in,
                                .out_valid(m_valid), .x_out(mx), .y_out(my));
  cordic_pipe #(.WIDTH(W), .ITER(16)) u_cordic (.clk, .rst, .in_valid, .in_ready(c_ready),
      .mode_cl(1'b0), .mode_rv(1'b0), .x_in, .y_in, .z_in, .in_tag(4'd0),
      .out_valid(c_valid), .out_ready(1'b1), .x_corr(cx), .y_corr(cy), .z(cz), .ovf(c_ovf), .out_tag(c_tag));

  real mq_x [$], mq_y [$], cq_x [$], cq_y [$];
  real m_worst = 0, c_worst = 0, m_sum = 0, c_sum = 0, m_abs = 0, c_abs = 0;
  int  n_m = 0, n_c = 0, n_sat = 0;

  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction

  // expected results, queued in input order for each engine
  always @(posedge clk) if (!rst && in_valid) begin
    real th, x0, y0, ex, ey;
    th = real'($signed(z_in)) * 2.0 * PI / TURN;
    x0 = real'($signed(x_in)) / QXY;
    y0 = real'($signed(y_in)) / QXY;
    ex = (x0 * $cos(th) - y0 * $sin(th)) * QXY;
    ey = (x0 * $sin(th) + y0 * $cos(th)) * QXY;
    mq_x.push_back(ex); mq_y.push_back(ey);
    cq_x.push_back(ex); cq_y.push_back(ey);
  end

  always @(posedge clk) if (!rst) begin
    if (m_valid) begin
      real ex, ey;
      ex = mq_x.pop_front(); ey = mq_y.pop_front();
      if (fabs(ex) < 32767 && fabs(ey) < 32767) begin
        if (fabs(mx - ex) > m_worst) m_worst = fabs(mx - ex);
        if (fabs(my - ey) > m_worst) m_worst = fabs(my - ey);
        m_sum += (mx - ex) + (my - ey); m_abs += fabs(mx - ex) + fabs(my - ey); n_m += 2;
      end else n_sat++;
    end
    if (c_valid) begin
      real ex, ey;
      ex = cq_x.pop_front(); ey = cq_y.pop_front();
      if (fabs(ex) < 32767 && fabs(ey) < 32767) begin
        if (fabs(cx - ex) > c_worst) c_worst = fabs(cx - ex);
        if (fabs(cy - ey) > c_worst) c_worst = fabs(cy - ey);
        c_sum += (cx - ex) + (cy - ey); c_abs += fabs(cx - ex) + fabs(cy - ey); n_c += 2;
      end
    end
  end

  task automatic report(input string id, input string what);
    $display("%s %-44s multipliers: worst %0.2f LSB, mean |e| %0.3f, bias %0.4f | CORDIC: worst %0.2f LSB, mean |e| %0.3f, bias %0.4f",
             id, what, m_worst, m_abs / n_m, m_sum / n_m, c_worst, c_abs / n_c, c_sum / n_c);
    m_worst = 0; c_worst = 0; m_sum = 0; c_sum = 0; m_abs = 0; c_abs = 0; n_m = 0; n_c = 0;
  endtask

  task automatic drain();
    @(negedge clk); in_valid = 0;
    repeat (40) @(negedge clk);
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    // M1
    for (int c = -32768; c < 32768; c += 16) begin
      @(negedge clk); in_valid = 1; x_in = 16384; y_in = 0; z_in = c;
    end
    drain();
    report("M1 ", "(1, 0) at 4,096 angles");
    // M2
    void'($urandom(2));
    for (int k = 0; k < 100000; k++) begin
      real r, a;
      r = 1.4 * $sqrt($urandom() / 4294967296.0);
      a = 2.0 * PI * ($urandom() / 4294967296.0);
      @(negedge clk); in_valid = 1;
      x_in = $rtoi(r * $cos(a) * QXY); y_in = $rtoi(r * $sin(a) * QXY);
      z_in = int'($urandom() & 16'hFFFF) - 32768;
    end
    drain();
    report("M2 ", "100,000 random vectors and angles");
    $display("DONE");
    $finish;
  end
endmodule
