module datapath #(
    parameter WIDTH = 8,
    parameter ITER = 8 )(
    input logic clk, rst,
    //control unit inputs
    input logic init, en, sigma, i, m,
    input logic signed [WIDTH - 1 : 0] x_in, y_in, z_in,
    output logic signed [WIDTH - 1 : 0] x, y, z
    );

    logic signed [WIDTH - 1 : 0] x_mux_2_reg, y_mux_2_reg, z_mux_2_reg;
    logic signed [WIDTH - 1 : 0] x_as_2_mux, y_as_2_mux, z_as_2_mux;
    logic signed [WIDTH - 1 : 0] xlane_shift, ylane_shift, zlane_shift, ylane_shift_gated;
    logic signed [WIDTH - 1 : 0] z_angle_mux_2_as;
    logic signed [WIDTH - 1 : 0] one_l_shift, atan_out;
    //input muxes
    cordic_mux #(.WIDTH(WIDTH)) x_mux(.sel0(x_as_2_mux), .sel1(x_in), .sel(init), .mux_out(x_mux_2_reg));
    cordic_mux #(.WIDTH(WIDTH)) y_mux(.sel0(y_as_2_mux), .sel1(y_in), .sel(init), .mux_out(y_mux_2_reg));
    cordic_mux #(.WIDTH(WIDTH)) z_mux(.sel0(z_as_2_mux), .sel1(z_in), .sel(init), .mux_out(z_mux_2_reg));
    //z mux angle sel
    cordic_mux #(.WIDTH(WIDTH)) z_angle_mux(.sel0(one_l_shift), .sel1(atan_out), .sel(m), .mux_out(z_angle_mux_2_as));

    //x y z registers
    sync_reg #(.WIDTH(WIDTH)) x(.clk(clk), .rst(rst), .en(en), .data_in(x_mux_2_reg), .data_out(x));
    sync_reg #(.WIDTH(WIDTH)) y(.clk(clk), .rst(rst), .en(en), .data_in(y_mux_2_reg), .data_out(y));
    sync_reg #(.WIDTH(WIDTH)) z(.clk(clk), .rst(rst), .en(en), .data_in(z_mux_2_reg), .data_out(z));

    //add sub
    add_sub #(.WIDTH(WIDTH)) x_lane(.a(x), .b(ylane_shift_gated), .add_sub(sigma),  .sum_diff(x_as_2_mux), .overflow());
    add_sub #(.WIDTH(WIDTH)) y_lane(.a(y), .b(xlane_shift), .add_sub(!sigma), .sum_diff(y_as_2_mux), .overflow());
    add_sub #(.WIDTH(WIDTH)) z_lane(.a(z), .b(z_angle_mux_2_as), .add_sub(sigma),  .sum_diff(z_as_2_mux), .overflow());

    //shifters
    shifter #(.WIDTH(WIDTH)) x_lane_shift(.data_in(x), .shift_amt(i), .data_out(xlane_shift));
    shifter #(.WIDTH(WIDTH)) y_lane_shift(.data_in(y), .shift_amt(i), .data_out(ylane_shift));
    shifter #(.WIDTH(WIDTH)) z_lane_shift(.data_in(z), .shift_amt(i), .data_out(zlane_shift));
    assign ylane_shift_gated = m ? ylane_shift : '0;

    atan_rom #(.WIDTH(WIDTH), .ITER(ITER))atan_rom(.atan_out(atan_out));
    one_shifted #(.WIDTH(WIDTH), .ITER(ITER)) one_shifted(.i(i), .one_l_shift(one_l_shift));
endmodule