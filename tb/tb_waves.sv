`timescale 1ns/1ps
// tb_waves.sv : two short runs that dump waveforms (+VCD=<file>, default waves.vcd) for the
// report; python/plot_waves.py draws them.
//   1. cordic_ss: rotate (0.5, 0) by 30 deg; a second rotation (by -60 deg) starts in the
//      out_valid clock and runs back to back. Shows start/ready, the FSM, i, the lanes converging.
//   2. cordic_pipe, 18 ranks: 30 rotations offered back to back (tags 1, 2, ...). While results
//      come out, the consumer stalls for 6 clocks: the skid buffer catches the result in flight,
//      in_ready drops, every rank holds, and nothing is lost or repeated.
// Both runs check their results against the expected values and print PASS or FAIL.
module tb_waves;
  localparam int W = 16, N = 16;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- iterative engine ----
  logic start = 0, mode_cl = 0, mode_rv = 0, out_valid, ready, ovf;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0, x_corr, y_corr, z;
  cordic_ss #(.WIDTH(W), .ITER(N)) ss (.clk, .rst, .x_in, .y_in, .z_in, .start, .mode_cl, .mode_rv,
      .out_valid, .ready, .x_corr, .y_corr, .z, .ovf);
  wire [1:0] ss_state = ss.u_control.state;          // 0 IDLE, 1 EXE, 2 DONE
  wire [3:0] ss_i = ss.u_control.i;
  wire signed [22:0] ss_x_lane = ss.x, ss_y_lane = ss.y, ss_z_lane = ss.z_lane;

  // ---- pipelined engine ----
  logic p_in_valid = 0, p_out_ready = 1, p_in_ready, p_out_valid, p_ovf;
  logic signed [W-1:0] p_x_in = 0, p_y_in = 0, p_z_in = 0, p_x, p_y, p_z;
  logic [3:0] p_in_tag = 0, p_out_tag;
  cordic_pipe #(.WIDTH(W), .ITER(N), .CUTS(20'h5FFFF)) pipe (.clk, .rst, .in_valid(p_in_valid),
      .in_ready(p_in_ready), .mode_cl(1'b0), .mode_rv(1'b0), .x_in(p_x_in), .y_in(p_y_in), .z_in(p_z_in),
      .in_tag(p_in_tag), .out_valid(p_out_valid), .out_ready(p_out_ready), .x_corr(p_x), .y_corr(p_y),
      .z(p_z), .ovf(p_ovf), .out_tag(p_out_tag));
  wire p_skid_full = pipe.s_v;                         // the skid entry holds a result

  localparam real PI = 3.14159265358979323846;
  function automatic int deg2z(real d); return $rtoi(d / 360.0 * 65536.0 + (d >= 0 ? 0.5 : -0.5)); endfunction
  function automatic bit near(int got, real want); return (got - want <= 2.0) && (want - got <= 2.0); endfunction

  int n_bad = 0, n_out = 0, expect_tag = 1;
  string vcd = "waves.vcd";

  // pipeline consumer: every result must come out once, in order, and be right
  always @(posedge clk) if (!rst && p_out_valid && p_out_ready) begin
    real a;
    a = 20.0 * expect_tag * PI / 180.0;
    if (p_out_tag != 4'(expect_tag) || !near(p_x, 0.5 * $cos(a) * 16384.0) || !near(p_y, 0.5 * $sin(a) * 16384.0))
      n_bad++;
    expect_tag++;
    n_out++;
  end

  initial begin
    int k;
    bit ok1, ok2, taken;
    void'($value$plusargs("VCD=%s", vcd));
    $dumpfile(vcd);
    $dumpvars(1, tb_waves);
    repeat (2) @(negedge clk);
    rst = 0;

    // 1. iterative engine: one rotation, then a second started in the out_valid clock
    @(negedge clk);
    x_in = 16'sd8192; y_in = 0; z_in = deg2z(30.0); start = 1;
    @(negedge clk); start = 0;
    while (!out_valid) @(negedge clk);
    ok1 = near(x_corr, 0.5 * $cos(PI / 6) * 16384.0) && near(y_corr, 0.5 * $sin(PI / 6) * 16384.0);
    z_in = deg2z(-60.0); start = 1;                                   // back to back
    @(negedge clk); start = 0;
    while (!out_valid) @(negedge clk);
    ok2 = near(x_corr, 0.5 * $cos(-PI / 3) * 16384.0) && near(y_corr, 0.5 * $sin(-PI / 3) * 16384.0);
    $display("%s iterative engine: two rotations, the second back to back", ok1 && ok2 ? "PASS" : "FAIL");
    repeat (4) @(negedge clk);

    // 2. pipelined engine: 30 operations offered back to back; the consumer stalls once
    fork
      begin
        k = 1;
        p_in_valid = 1; p_x_in = 16'sd8192; p_z_in = deg2z(20.0); p_in_tag = 4'(1);
        while (k <= 30) begin
          taken = p_in_ready;                                         // holds until the next edge
          @(negedge clk);
          if (taken) begin
            k++;
            if (k <= 30) begin p_z_in = deg2z(20.0 * k); p_in_tag = 4'(k); end
          end
        end
        p_in_valid = 0;
      end
      begin
        wait (n_out == 4);
        @(negedge clk); p_out_ready = 0;
        repeat (6) @(negedge clk);
        p_out_ready = 1;
      end
    join
    wait (n_out == 30);
    repeat (3) @(negedge clk);
    $display("%s pipelined engine: 30 results in order, through a 6-clock stall (%0d wrong)",
             n_bad == 0 && n_out == 30 ? "PASS" : "FAIL", n_bad);
    $display("DONE: %s", ok1 && ok2 && n_bad == 0 && n_out == 30 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
