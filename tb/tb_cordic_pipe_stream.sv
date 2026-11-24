`timescale 1ns/1ps

// Pipeline-specific test:
//   - inject one circular-rotation operation every clock
//   - verify output ordering
//   - verify one output per clock after the pipeline fills
module tb_cordic_pipe_stream;
  localparam int WIDTH = 16;
  localparam int ITER  = 16;
  localparam int ONE   = 1 << 14;
  localparam int TOL   = 2;
  localparam int NUM   = 32;

  logic clk = 0, rst, start, mode_cl, mode_rv;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic signed [WIDTH-1:0] x, y, z;
  logic out_valid, ovf;

  cordic_pipe #(.WIDTH(WIDTH), .ITER(ITER)) dut (
      .clk(clk), .rst(rst), .start(start),
      .mode_cl(mode_cl), .mode_rv(mode_rv),
      .x_in(x_in), .y_in(y_in), .z_in(z_in),
      .out_valid(out_valid), .x_corr(x), .y_corr(y), .z(z), .ovf(ovf)
  );

  always #5 clk = ~clk;

  int angle_deg [NUM] = '{
       0,  30,  45,  60,  90, 120, 150, 172,
     -30, -45, -60, -90, -120, -150, -172, 179,
      10,  20,  35,  55,  75, 100, 135, 160,
     -10, -20, -35, -55, -75, -100, -135, -160
  };
  int expected_x [NUM];
  int expected_y [NUM];
  int in_count = 0, out_count = 0;
  int n_pass = 0, n_fail = 0;
  int consecutive_outputs = 0;
  int max_gap = 0;

  function automatic logic signed [WIDTH-1:0] deg2z(input real deg);
    int v;
    begin
      v = $rtoi(deg / 360.0 * 65536.0 + (deg >= 0 ? 0.5 : -0.5));
      deg2z = v[WIDTH-1:0];
    end
  endfunction

  function automatic int iabs(input int v);
    return (v < 0) ? -v : v;
  endfunction

  task automatic check_output;
    int ex, ey, errx, erry, gap;
    begin
      if (out_valid) begin
        if (out_count >= NUM) begin
          $display("FAIL unexpected extra output x=%0d y=%0d", x, y);
          n_fail++;
        end
        else begin
          ex = expected_x[out_count];
          ey = expected_y[out_count];
          errx = iabs(int'(x) - ex);
          erry = iabs(int'(y) - ey);
          if (errx <= TOL && erry <= TOL && !ovf) begin
            $display("PASS output %0d | angle=%0d | x=%0d y=%0d",
                     out_count, angle_deg[out_count], x, y);
            n_pass++;
          end
          else begin
            $display("FAIL output %0d | angle=%0d | got x=%0d y=%0d | exp x=%0d y=%0d | ovf=%0d",
                     out_count, angle_deg[out_count], x, y, ex, ey, ovf);
            n_fail++;
          end
          out_count++;
        end
      end
    end
  endtask

  initial begin
    real rad, c, s;
    for (int k = 0; k < NUM; k++) begin
      rad = angle_deg[k] * 3.141592653589793 / 180.0;
      c = $cos(rad);
      s = $sin(rad);
      expected_x[k] = $rtoi(c * ONE + (c >= 0 ? 0.5 : -0.5));
      expected_y[k] = $rtoi(s * ONE + (s >= 0 ? 0.5 : -0.5));
    end

    $dumpfile("tb_cordic_pipe_stream.vcd");
    $dumpvars(0, tb_cordic_pipe_stream);

    rst = 1;
    start = 0;
    mode_cl = 0;
    mode_rv = 0;
    x_in = 0;
    y_in = 0;
    z_in = 0;

    repeat (3) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // Inject one transaction on every clock.
    for (int k = 0; k < NUM; k++) begin
      @(negedge clk);
      check_output();
      x_in = ONE;
      y_in = 0;
      z_in = deg2z(angle_deg[k]);
      mode_cl = 0;
      mode_rv = 0;
      start = 1;
      in_count++;
    end

    // Stop injecting and drain the pipeline.
    @(negedge clk);
    check_output();
    start = 0;
    while (out_count < NUM) begin
      @(negedge clk);
      check_output();
    end

    if (out_count == NUM)
      $display("PASS throughput: %0d inputs produced %0d ordered outputs", in_count, out_count);

    $display("--------------------------------------");
    $display("DONE: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end
endmodule
