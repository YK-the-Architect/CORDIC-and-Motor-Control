// tb_common.svh : helpers shared by the system-level testbenches.
// Include it inside a testbench module that already declares:
//   localparam int W, N;  logic clk, rst, start, mode_cl, mode_rv, out_valid, ovf;
//   logic signed [W-1:0] x_in, y_in, z_in, x_corr, y_corr, z;  and the cordic_ss instance.
// Formats: x, y are Q2.(W-2); z is a binary angle (2^W = 360 deg) in circular mode and
// Q1.(W-1) in linear mode. Errors are reported in LSBs of the output.

localparam real PI   = 3.14159265358979323846;
localparam real QXY  = real'(1 << (W - 2));
localparam real QZL  = real'(1 << (W - 1));
localparam real TURN = real'(1 << W);
localparam int  WMAX = (1 << (W - 1)) - 1;
localparam int  WMIN = -(1 << (W - 1));

int n_pass = 0, n_fail = 0;

function automatic real fabs(real v); return v < 0 ? -v : v; endfunction

// real value -> nearest code, clamped to the W-bit range
function automatic int q(real v, real scale);
  real s; int c;
  s = v * scale;
  c = $rtoi(s + (s >= 0 ? 0.5 : -0.5));
  if (c > WMAX) c = WMAX;
  if (c < WMIN) c = WMIN;
  return c;
endfunction

function automatic int deg2z(real deg);   // angle -> binary angle code, wrapped
  int c;
  c = $rtoi(deg / 360.0 * TURN + (deg >= 0 ? 0.5 : -0.5));
  c = c & ((1 << W) - 1);
  return c >= (1 << (W - 1)) ? c - (1 << W) : c;
endfunction

function automatic real wrap_turn(real d);  // angle error into [-TURN/2, TURN/2)
  while (d >=  TURN / 2) d -= TURN;
  while (d <  -TURN / 2) d += TURN;
  return d;
endfunction

// one operation: inputs + start pulse, wait for out_valid, sample the outputs.
// lat = clocks from the start clock to the out_valid clock.
task automatic op(input bit cl, input bit rv, input int xi, input int yi, input int zi,
                  output int xo, output int yo, output int zo, output bit of, output int lat);
  @(negedge clk);
  mode_cl = cl; mode_rv = rv; x_in = xi; y_in = yi; z_in = zi; start = 1;
  @(negedge clk);
  start = 0; lat = 1;
  while (!out_valid && lat < 4 * N + 10) begin @(negedge clk); lat++; end
  if (!out_valid) lat = -1;
  xo = x_corr; yo = y_corr; zo = z; of = ovf;
  @(negedge clk);
endtask

task automatic result(input string id, input string what, input bit ok, input string detail = "");
  $display("%s %-4s %-44s %s", ok ? "PASS" : "FAIL", id, what, detail);
  if (ok) n_pass++; else n_fail++;
endtask

task automatic reset_dut();
  rst = 1; start = 0; mode_cl = 0; mode_rv = 0; x_in = 0; y_in = 0; z_in = 0;
  repeat (3) @(negedge clk);
  rst = 0;
endtask
