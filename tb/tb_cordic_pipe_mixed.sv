`timescale 1ns/1ps

// Mixed-mode pipeline test. A different operation is injected every clock.
module tb_cordic_pipe_mixed;
  localparam int W = 16, N = 16;
  localparam real PI = 3.14159265358979323846;
  localparam real QXY = real'(1 << (W-2));
  localparam real QZL = real'(1 << (W-1));
  localparam real TURN = real'(1 << W);
  localparam int WMAX = (1 << (W-1)) - 1;
  localparam int WMIN = -(1 << (W-1));
  localparam int NUM = 8, TOL = 3;

  logic clk = 0, rst, start, mode_cl, mode_rv, out_valid, ovf;
  logic signed [W-1:0] x_in, y_in, z_in, x, y, z;
  always #5 clk = ~clk;

  cordic_pipe #(.WIDTH(W), .ITER(N)) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .mode_cl(mode_cl),
    .mode_rv(mode_rv),
    .x_in(x_in),
    .y_in(y_in),
    .z_in(z_in),
    .out_valid(out_valid),
    .x_corr(x),
    .y_corr(y),
    .z(z),
    .ovf(ovf)
  );

  int xi[NUM], yi[NUM], zi[NUM];
  int ex[NUM], ey[NUM], ez[NUM];
  bit cl[NUM], rv[NUM];
  string name[NUM];
  int n_pass = 0, n_fail = 0, out_idx = 0;

  function automatic int q(input real v, input real scale);
    int c;
    begin
      c = $rtoi(v * scale + (v >= 0 ? 0.5 : -0.5));
      if (c > WMAX) c = WMAX;
      if (c < WMIN) c = WMIN;
      q = c;
    end
  endfunction

  function automatic int deg2z(input real deg);
    int c;
    begin
      c = $rtoi(deg / 360.0 * TURN + (deg >= 0 ? 0.5 : -0.5));
      c = c & ((1 << W) - 1);
      deg2z = (c >= (1 << (W-1))) ? c - (1 << W) : c;
    end
  endfunction

  function automatic int clamp(input real v, input real scale);
    clamp = q(v, scale);
  endfunction

  function automatic int iabs(input int v);
    return (v < 0) ? -v : v;
  endfunction

  task automatic check_output;
    int dx, dy, dz;
    begin
      if (out_valid) begin
        if (out_idx >= NUM) begin
          $display("FAIL unexpected extra output");
          n_fail++;
        end
        else begin
          dx = iabs(int'(x) - ex[out_idx]);
          dy = iabs(int'(y) - ey[out_idx]);
          dz = iabs(int'(z) - ez[out_idx]);
          if (dx <= TOL && dy <= TOL && dz <= TOL && !ovf) begin
            $display("PASS %0d %-20s | x=%0d y=%0d z=%0d",
                     out_idx, name[out_idx], x, y, z);
            n_pass++;
          end
          else begin
            $display("FAIL %0d %-20s | got (%0d,%0d,%0d), expected (%0d,%0d,%0d), ovf=%0d",
                     out_idx, name[out_idx], x, y, z,
                     ex[out_idx], ey[out_idx], ez[out_idx], ovf);
            n_fail++;
          end
          out_idx++;
        end
      end
    end
  endtask

  initial begin
    real a, xr, yr, zr;

    // 0: circular rotation, +30 degrees
    name[0] = "circ rotation +30"; cl[0]=0; rv[0]=0;
    xi[0]=q(1.0,QXY); yi[0]=q(0.0,QXY); zi[0]=deg2z(30.0);
    ex[0]=q($cos(30.0*PI/180.0),QXY); ey[0]=q($sin(30.0*PI/180.0),QXY); ez[0]=0;

    // 1: circular vectoring, (0.5, 0.5)
    name[1] = "circ vector +45"; cl[1]=0; rv[1]=1;
    xi[1]=q(0.5,QXY); yi[1]=q(0.5,QXY); zi[1]=0;
    ex[1]=q($sqrt(0.5*0.5+0.5*0.5),QXY); ey[1]=0; ez[1]=deg2z(45.0);

    // 2: linear rotation, y = y0 + x*z = 0.5
    name[2] = "linear multiply"; cl[2]=1; rv[2]=0;
    xi[2]=q(0.5,QXY); yi[2]=q(0.25,QXY); zi[2]=q(0.5,QZL);
    ex[2]=xi[2]; ey[2]=q((yi[2]/QXY)+(xi[2]/QXY)*(zi[2]/QZL),QXY); ez[2]=0;

    // 3: linear vectoring, z = y/x = 0.5
    name[3] = "linear divide"; cl[3]=1; rv[3]=1;
    xi[3]=q(1.0,QXY); yi[3]=q(0.5,QXY); zi[3]=0;
    ex[3]=xi[3]; ey[3]=0; ez[3]=q(0.5,QZL);

    // 4: circular rotation, -90 degrees
    name[4] = "circ rotation -90"; cl[4]=0; rv[4]=0;
    xi[4]=q(1.0,QXY); yi[4]=0; zi[4]=deg2z(-90.0);
    ex[4]=0; ey[4]=q(-1.0,QXY); ez[4]=0;

    // 5: circular vectoring, quadrant II
    name[5] = "circ vector +135"; cl[5]=0; rv[5]=1;
    xi[5]=q(-0.5,QXY); yi[5]=q(0.5,QXY); zi[5]=0;
    ex[5]=q($sqrt(0.5*0.5+0.5*0.5),QXY); ey[5]=0; ez[5]=deg2z(135.0);

    // 6: linear rotation with negative operands
    name[6] = "linear multiply neg"; cl[6]=1; rv[6]=0;
    xi[6]=q(-0.75,QXY); yi[6]=q(-0.25,QXY); zi[6]=q(-0.5,QZL);
    ex[6]=xi[6]; ey[6]=q((yi[6]/QXY)+(xi[6]/QXY)*(zi[6]/QZL),QXY); ez[6]=0;

    // 7: linear vectoring with a negative divisor
    name[7] = "linear divide neg"; cl[7]=1; rv[7]=1;
    xi[7]=q(-1.0,QXY); yi[7]=q(0.25,QXY); zi[7]=0;
    ex[7]=q(1.0,QXY); ey[7]=0; ez[7]=q(-0.25,QZL);

    $dumpfile("tb_cordic_pipe_mixed.vcd");
    $dumpvars(0, tb_cordic_pipe_mixed);
    rst=1; start=0; mode_cl=0; mode_rv=0; x_in=0; y_in=0; z_in=0;
    repeat (3) @(negedge clk);
    rst=0;
    repeat (2) @(negedge clk);

    for (int k=0; k<NUM; k++) begin
      @(negedge clk);
      check_output();
      mode_cl=cl[k]; mode_rv=rv[k]; x_in=xi[k]; y_in=yi[k]; z_in=zi[k]; start=1;
    end

    @(negedge clk);
    check_output();
    start=0;
    while (out_idx < NUM) begin
      @(negedge clk);
      check_output();
    end

    $display("--------------------------------------");
    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
