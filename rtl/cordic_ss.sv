//single cycle implmenetation top level
module cordic_ss #(
    parameter WIDTH = 8,
    parameter ITER = 8,
    //guard bits in the lanes (RTL change 3). ceil(log2 N) + 1: tb_datatypes showed divide needs
    //the extra bit to stay within 2 LSB at W = 16 (2.4 LSB with ceil(log2 N)). 0 turns them off.
    parameter G = $clog2(ITER) + 1
)
(
    input logic clk, rst,
    input logic signed [WIDTH - 1 : 0]x_in, y_in, z_in,
    input logic start,
    input logic mode_cl, mode_rv,
    output logic out_valid,
    output logic signed [WIDTH - 1 : 0] x_corr, y_corr, z,
    //RTL change 5: a result saturated, a lane overflowed, or a divide was out of range.
    //Valid with out_valid; holds until the next start.
    output logic ovf
);

    //lanes inside the engine are WIDTH + 2 headroom bits + G guard bits wide
    localparam int IW = WIDTH + 2 + G;
    logic signed [IW - 1 : 0] x, y, z_lane;

    logic init, en, sigma, m, scale_en, lane_ovf, sat, ovf_hold, div_bad;
    logic [$clog2(ITER) - 1 : 0] i;

    control #(.WIDTH(WIDTH), .ITER(ITER)) u_control (
    .y_msb(y[IW - 1]),
    .z_msb(z_lane[IW - 1]),
    .*
    );

    datapath #(
    .WIDTH(WIDTH), .ITER(ITER), .G(G))
    u_datapath (.z(z_lane), .*);

    error_correction #(
    .WIDTH(WIDTH), .G(G))
    u_error_correction(.z(z_lane), .z_corr(z), .*);

    //divide out of range: |y| >= |x| has no answer in z's range, and x = 0 divides by zero
    function automatic logic [WIDTH:0] mag(input logic signed [WIDTH-1:0] v);
        logic signed [WIDTH:0] w;
        w = v;
        return w < 0 ? -w : w;
    endfunction
    assign div_bad = mode_cl && mode_rv && (mag(y_in) >= mag(x_in));

    //sticky ovf: cleared when an operation starts (set at once for a bad divide), then set
    //by any lane overflow while iterating or by a saturated result
    always_ff @(posedge clk) begin
        if (rst)       ovf_hold <= 1'b0;
        else if (init) ovf_hold <= div_bad;
        else           ovf_hold <= ovf_hold | (en & lane_ovf) | (out_valid & sat);
    end
    assign ovf = ovf_hold | (out_valid & sat);

endmodule
