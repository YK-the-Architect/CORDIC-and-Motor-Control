`timescale 1ps/1ps
// syn/tb_power.sv : runs a synthesized netlist (gate-level, zero delay) next to its RTL on the
// same operations, checks every result matches, and dumps the netlist's switching activity
// (activity.vcd) for OpenSTA's power report (syn/run_ppa.py --power).
// Workload: rotations (Park-like), |(x, y)| <= 1, random angles, as fast as the engine takes them
// (GAP = 1: one per clock; cordic_ss: back to back). Build with +define+SS, +define+PIPE or
// +define+MULT; the netlist's top module must be renamed <top>_gl. Run options: +GAP=<n> (clocks
// per operation, PIPE and MULT) and +VCD=<file>.
// With gate delays (VCS): +define+SDF_FILE=\"<file.sdf>\" annotates the netlist (syn/gls_vcs.sh);
// set PERIOD (ps) above the netlist's fastest clock.
module tb_power;
  parameter int PERIOD   = 1250;          // ps, the clock the power is reported at
  parameter int CLOCKS   = 3000;
  parameter int GAP      = 1;             // PIPE and MULT: one operation every GAP clocks
  parameter bit OUT_WAIT = 0;             // SS
  parameter logic [19:0] CUTS = '1;       // PIPE
  parameter bit STALL    = 1;             // PIPE
  parameter int G        = 5;             // SS and PIPE: guard bits (the engines' default at N = 16)
  localparam int W = 16;
  localparam real PI = 3.14159265358979323846;

  logic clk = 0, rst = 1;
  always #(PERIOD / 2) clk = ~clk;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0;
  int n_ops = 0, n_cmp = 0, n_bad = 0, cyc = 0, gap = GAP;
  string vcd = "activity.vcd";
  initial begin
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("VCD=%s", vcd));
  end

  task automatic next_inputs();
    real r, a;
    r = $sqrt($urandom() / 4294967296.0);
    a = 2.0 * PI * ($urandom() / 4294967296.0);
    x_in = $rtoi(r * $cos(a) * 16384.0);
    y_in = $rtoi(r * $sin(a) * 16384.0);
    z_in = int'($urandom() & 16'hFFFF) - 32768;
    n_ops++;
  endtask

`ifdef SS
  logic start = 0, gv, rv, go, ro;
  logic signed [W-1:0] gx, gy, gz, rx, ry, rz;
  cordic_ss_gl dut (.clk, .rst, .x_in, .y_in, .z_in, .start, .mode_cl(1'b0), .mode_rv(1'b0),
                    .out_valid(gv), .x_corr(gx), .y_corr(gy), .z(gz), .ovf(go));
  cordic_ss #(.WIDTH(W), .ITER(16), .G(G), .OUT_WAIT(OUT_WAIT)) ref_rtl (.clk, .rst, .x_in, .y_in, .z_in, .start,
      .mode_cl(1'b0), .mode_rv(1'b0), .out_valid(rv), .x_corr(rx), .y_corr(ry), .z(rz), .ovf(ro));
  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    next_inputs(); start = 1;                       // first operation from IDLE
    forever begin
      @(negedge clk);
      start = 0;
      if (gv) begin next_inputs(); start = 1; end   // DONE: the next one back to back
    end
  end
  always @(posedge clk) if (!rst) begin
    if (gv !== rv || (rv && {gx, gy, gz, go} !== {rx, ry, rz, ro})) n_bad++;
    if (rv) n_cmp++;
  end
`elsif PIPE
  logic in_valid = 0, gr, rr, gv, rv, go, ro;
  logic signed [W-1:0] gx, gy, gz, rx, ry, rz;
  logic [3:0] gt, rt;
  cordic_pipe_gl dut (.clk, .rst, .in_valid, .in_ready(gr), .mode_cl(1'b0), .mode_rv(1'b0), .x_in, .y_in, .z_in,
                      .in_tag(4'(n_ops)), .out_valid(gv), .out_ready(1'b1), .x_corr(gx), .y_corr(gy), .z(gz),
                      .ovf(go), .out_tag(gt));
  cordic_pipe #(.WIDTH(W), .ITER(16), .G(G), .CUTS(CUTS), .STALL(STALL)) ref_rtl (.clk, .rst, .in_valid, .in_ready(rr),
      .mode_cl(1'b0), .mode_rv(1'b0), .x_in, .y_in, .z_in, .in_tag(4'(n_ops)), .out_valid(rv), .out_ready(1'b1),
      .x_corr(rx), .y_corr(ry), .z(rz), .ovf(ro), .out_tag(rt));
  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    forever begin
      @(negedge clk);
      in_valid = (cyc % gap) == 0;
      if (in_valid) next_inputs();
    end
  end
  always @(posedge clk) if (!rst) begin
    cyc++;
    if (gv !== rv || gr !== rr || (rv && {gx, gy, gz, go, gt} !== {rx, ry, rz, ro, rt})) n_bad++;
    if (rv) n_cmp++;
  end
`elsif MULT
  logic in_valid = 0, gv, rv;
  logic signed [W-1:0] gx, gy, rx, ry;
  mult_rot_gl dut (.clk, .rst, .in_valid, .x_in, .y_in, .z_in, .out_valid(gv), .x_out(gx), .y_out(gy));
  mult_rot #(.WIDTH(W)) ref_rtl (.clk, .rst, .in_valid, .x_in, .y_in, .z_in, .out_valid(rv), .x_out(rx), .y_out(ry));
  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    forever begin
      @(negedge clk);
      in_valid = (cyc % gap) == 0;
      if (in_valid) next_inputs();
    end
  end
  always @(posedge clk) if (!rst) begin
    cyc++;
    if (gv !== rv || (rv && {gx, gy} !== {rx, ry})) n_bad++;
    if (rv) n_cmp++;
  end
`endif

`ifdef SDF_FILE
  initial $sdf_annotate(`SDF_FILE, dut);
`endif

  initial begin
    #1;
    $dumpfile(vcd);
    $dumpvars(0, dut);
    #(PERIOD * CLOCKS);
    $display("GLS %0d operations in %0d clocks, %0d results compared, %0d different", n_ops, CLOCKS, n_cmp, n_bad);
    $display("%s gate-level netlist matches the RTL", n_bad == 0 && n_cmp > 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
