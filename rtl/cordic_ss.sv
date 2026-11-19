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
    output logic signed [WIDTH - 1 : 0] x_corr, y_corr, z
);

    //lanes inside the engine are WIDTH + 2 headroom bits + G guard bits wide
    localparam int IW = WIDTH + 2 + G;
    logic signed [IW - 1 : 0] x, y, z_lane;

    logic init, en, sigma, m, scale_en;
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


endmodule
