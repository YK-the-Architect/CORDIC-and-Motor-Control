//single cycle implmenetation top level
module cordic_ss #(
    parameter WIDTH = 8,
    parameter ITER = 8
)
(
    input logic clk, rst,
    input logic signed [WIDTH - 1 : 0]x_in, y_in, z_in,
    input logic start,
    input logic mode_cl, mode_rv,
    output logic out_valid,
    output logic signed [WIDTH - 1 : 0] x_corr, y_corr, z
);

    logic signed [WIDTH - 1 : 0] x , y;

    logic init, en, sigma, m, scale_en;
    logic [$clog2(ITER) - 1 : 0] i;

    control #(.WIDTH(WIDTH), .ITER(ITER)) u_control (
    .y_msb(y[WIDTH - 1]), 
    .z_msb(z[WIDTH - 1]),
    .*
    );

    datapath #(
    .WIDTH(WIDTH), .ITER(ITER))
    u_datapath (.*);

    error_correction #(
    .WIDTH(WIDTH))
    u_error_correction(.*);


endmodule
